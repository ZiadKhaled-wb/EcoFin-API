-- =============================================================================
-- C02 review fix (EC-43, D44): restoring a product locks its category and tax class.
--
-- The C02 restore checked `... AND archived_at IS NOT NULL FOR SHARE`. A locking clause only
-- locks the rows its query returns, so an ACTIVE category (or tax class) was not locked: a
-- concurrent category archive could commit between the check and the restore, leaving an active
-- product in an archived category. Now the rows are locked first (FOR SHARE, whatever their
-- state), then checked: a concurrent archive (FOR UPDATE) either waits for this restore, or has
-- already committed and the restore sees it. Behaviour is otherwise unchanged; grants are kept
-- (CREATE OR REPLACE keeps them).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.set_product_archived(p_id uuid, p_archived boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_old public.products;
    v_category_archived timestamptz; v_tax_archived timestamptz;
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    IF p_archived IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: archived' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_old FROM public.products
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF (v_old.archived_at IS NOT NULL) = p_archived THEN
        RETURN;                                      -- same state: nothing, no audit row
    END IF;

    IF NOT p_archived THEN
        IF v_old.category_id IS NOT NULL THEN
            SELECT c.archived_at INTO v_category_archived FROM public.categories c
            WHERE c.id = v_old.category_id AND c.organization_id = v_org FOR SHARE;
            IF v_category_archived IS NOT NULL THEN
                RAISE EXCEPTION 'PRODUCT_CATEGORY_ARCHIVED' USING ERRCODE = 'P0001';
            END IF;
        END IF;
        SELECT t.archived_at INTO v_tax_archived FROM public.tax_classes t
        WHERE t.id = v_old.tax_class_id AND t.organization_id = v_org FOR SHARE;
        IF v_tax_archived IS NOT NULL THEN
            RAISE EXCEPTION 'TAX_CLASS_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    UPDATE public.products SET
        archived_at = CASE WHEN p_archived THEN now() END,
        is_active = NOT p_archived,
        updated_by = v_emp
    WHERE id = p_id;
    PERFORM app.write_audit(CASE WHEN p_archived THEN 'product.archived' ELSE 'product.restored' END,
        'product', p_id,
        p_before => jsonb_build_object('archived_at', v_old.archived_at),
        p_after => (SELECT jsonb_build_object('archived_at', x.archived_at) FROM public.products x WHERE x.id = p_id),
        p_severity => CASE WHEN p_archived THEN 'warning' ELSE 'info' END::public.audit_severity);
END;
$$;
