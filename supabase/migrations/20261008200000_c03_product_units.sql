-- =============================================================================
-- C03 · Barcode labels (EC-44, D45)
--
-- Labels are rendered and printed by the client (templates, barcode drawing, printer or PDF);
-- nothing is stored. The only server piece is this read: the serialized units of a product, so
-- a label can be printed per unit (its serial / IMEI as the barcode).
--
-- list_product_units(product, status): any employee; units in branches the caller can access
-- (OWNER: all branches); status 'in_stock' by default, any unit_status, or 'all'. Another
-- shop's or a missing product -> PRODUCT_NOT_FOUND. A product without units answers [].
-- Numbered after the newest migration on main (D39). No table changes.
-- =============================================================================

CREATE FUNCTION public.list_product_units(p_product_id uuid, p_status text DEFAULT 'in_stock')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_status text := COALESCE(p_status, 'in_stock');
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF v_status <> 'all' AND NOT EXISTS (
        SELECT 1 FROM pg_catalog.pg_enum e
        WHERE e.enumtypid = 'public.unit_status'::regtype AND e.enumlabel = v_status) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: status' USING ERRCODE = 'P0001';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.products p WHERE p.id = p_product_id AND p.organization_id = v_org) THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', u.id, 'serial', u.serial, 'branch_id', u.branch_id,
                                            'status', u.status) ORDER BY u.serial, u.id)
        FROM public.units u
        WHERE u.organization_id = v_org AND u.product_id = p_product_id
          AND (v_status = 'all' OR u.status::text = v_status)
          AND app.has_branch_access(u.branch_id)), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.list_product_units(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_product_units(uuid, text) TO authenticated;
