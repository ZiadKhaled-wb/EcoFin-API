-- =============================================================================
-- C01 · Categories (EC-42)
--
-- Create, rename, nest (one level), archive and restore product categories. Every employee can
-- read them; the writes need catalog.manage and write one audit row each (D19).
--
-- Numbered after the newest migration on main (D39). Everything below is NEW: the baseline's
-- categories table, its UNIQUE (organization_id, name) (archived rows included), the composite
-- parent FK, CHECK (parent_id IS DISTINCT FROM id), the index, the RLS tenant policy, the
-- set_updated_at trigger and the no-delete trigger stay exactly as they are.
--
-- Filter helper for the later slices (C02 catalog, S06 POS, D01-D03 reports):
--     product.category_id = ANY(app.category_with_children(org, :id))
-- selects the category together with its subcategories; an unknown id or another shop's id
-- answers an empty array. Every slice that filters by a category MUST use this helper (D42).
-- =============================================================================

-- 1. Row shape (the list and the audit before/after) ---------------------------------------------

CREATE FUNCTION app.category_json(c public.categories)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = ''
AS $$
    SELECT jsonb_build_object('id', c.id, 'name', c.name, 'parent_id', c.parent_id,
        'archived_at', c.archived_at, 'created_at', c.created_at, 'updated_at', c.updated_at)
$$;
REVOKE ALL ON FUNCTION app.category_json(public.categories) FROM PUBLIC, anon, authenticated;

-- 2. Reads: any signed-in employee (the catalog, the POS and the reports filter by them) --------

CREATE FUNCTION public.list_categories()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    -- Active first, then archived; inside each, parents in name order, each followed by its
    -- children in name order (a child sorts under its parent's name).
    RETURN COALESCE((
        SELECT jsonb_agg(
            app.category_json(c) || jsonb_build_object('active_product_count', COALESCE(cnt.n, 0))
            ORDER BY (c.archived_at IS NOT NULL), COALESCE(pc.name, c.name),
                     (c.parent_id IS NOT NULL), c.name, c.id)
        FROM public.categories c
        LEFT JOIN public.categories pc ON pc.id = c.parent_id AND pc.organization_id = c.organization_id
        LEFT JOIN (
            SELECT p.category_id, count(*)::integer AS n
            FROM public.products p
            WHERE p.organization_id = v_org AND p.category_id IS NOT NULL AND p.archived_at IS NULL
            GROUP BY p.category_id
        ) cnt ON cnt.category_id = c.id
        WHERE c.organization_id = v_org), '[]'::jsonb);
END;
$$;

-- 3. Writes (catalog.manage): create ---------------------------------------------------------------

CREATE FUNCTION public.create_category(p_name text, p_parent_id uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_name text; v_parent public.categories%ROWTYPE; v_id uuid;
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    v_name := COALESCE(btrim(p_name), '');
    IF length(v_name) < 1 OR length(v_name) > 60 THEN
        RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    -- Unique per shop, archived categories included (the constraint counts them too).
    IF EXISTS (SELECT 1 FROM public.categories WHERE organization_id = v_org AND name = v_name) THEN
        RAISE EXCEPTION 'CATEGORY_NAME_TAKEN' USING ERRCODE = 'P0001';
    END IF;
    IF p_parent_id IS NOT NULL THEN
        SELECT * INTO v_parent FROM public.categories
        WHERE id = p_parent_id AND organization_id = v_org;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF v_parent.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'CATEGORY_PARENT_ARCHIVED' USING ERRCODE = 'P0001';
        END IF;
        IF v_parent.parent_id IS NOT NULL THEN
            RAISE EXCEPTION 'CATEGORY_DEPTH' USING ERRCODE = 'P0001';   -- one level only
        END IF;
    END IF;
    INSERT INTO public.categories (organization_id, name, parent_id, created_by, updated_by)
    VALUES (v_org, v_name, p_parent_id, v_emp, v_emp)
    RETURNING id INTO v_id;
    PERFORM app.write_audit('category.created', 'category', v_id,
        p_after => (SELECT app.category_json(c) FROM public.categories c WHERE c.id = v_id));
    RETURN v_id;
EXCEPTION
    WHEN unique_violation THEN                       -- a name taken in a race
        RAISE EXCEPTION 'CATEGORY_NAME_TAKEN' USING ERRCODE = 'P0001';
    WHEN check_violation OR not_null_violation THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: category' USING ERRCODE = 'P0001';
END;
$$;

-- 4. Writes: partial update (name, parent_id) -----------------------------------------------------

CREATE FUNCTION public.update_category(p_id uuid, p_changes jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_cat public.categories%ROWTYPE; v_parent public.categories%ROWTYPE;
    v_key text; c jsonb := p_changes; v_name text; v_new_parent uuid;
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    IF c IS NULL OR jsonb_typeof(c) <> 'object' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: body' USING ERRCODE = 'P0001';
    END IF;
    SELECT k INTO v_key FROM jsonb_object_keys(c) k
    WHERE k <> ALL (ARRAY['name', 'parent_id']) LIMIT 1;
    IF v_key IS NOT NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: %', v_key USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_cat FROM public.categories
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF v_cat.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';   -- restore it first
    END IF;

    v_name := CASE WHEN c ? 'name' THEN COALESCE(btrim(c ->> 'name'), '') ELSE v_cat.name END;
    v_new_parent := CASE
        WHEN NOT (c ? 'parent_id') THEN v_cat.parent_id
        WHEN jsonb_typeof(c -> 'parent_id') = 'null' THEN NULL
        ELSE (c ->> 'parent_id')::uuid END;

    IF v_name = v_cat.name AND v_new_parent IS NOT DISTINCT FROM v_cat.parent_id THEN
        RETURN;                                     -- no change: no update, no audit row
    END IF;

    IF c ? 'name' THEN
        IF length(v_name) < 1 OR length(v_name) > 60 THEN
            RAISE EXCEPTION 'NAME_REQUIRED' USING ERRCODE = 'P0001';
        END IF;
        IF EXISTS (SELECT 1 FROM public.categories
                   WHERE organization_id = v_org AND name = v_name AND id <> p_id) THEN
            RAISE EXCEPTION 'CATEGORY_NAME_TAKEN' USING ERRCODE = 'P0001';
        END IF;
    END IF;

    IF c ? 'parent_id' AND v_new_parent IS DISTINCT FROM v_cat.parent_id THEN
        IF v_new_parent = p_id THEN
            RAISE EXCEPTION 'CATEGORY_DEPTH' USING ERRCODE = 'P0001';
        END IF;
        IF v_new_parent IS NOT NULL THEN
            SELECT * INTO v_parent FROM public.categories
            WHERE id = v_new_parent AND organization_id = v_org;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
            END IF;
            IF v_parent.archived_at IS NOT NULL THEN
                RAISE EXCEPTION 'CATEGORY_PARENT_ARCHIVED' USING ERRCODE = 'P0001';
            END IF;
            IF v_parent.parent_id IS NOT NULL THEN
                RAISE EXCEPTION 'CATEGORY_DEPTH' USING ERRCODE = 'P0001';   -- a child as a parent
            END IF;
        END IF;
        IF EXISTS (SELECT 1 FROM public.categories
                   WHERE organization_id = v_org AND parent_id = p_id) THEN
            RAISE EXCEPTION 'CATEGORY_DEPTH' USING ERRCODE = 'P0001';   -- it has children itself
        END IF;
    END IF;

    UPDATE public.categories SET name = v_name, parent_id = v_new_parent, updated_by = v_emp
    WHERE id = p_id;
    PERFORM app.write_audit('category.updated', 'category', p_id,
        p_before => app.category_json(v_cat),
        p_after => (SELECT app.category_json(x) FROM public.categories x WHERE x.id = p_id));
EXCEPTION
    WHEN unique_violation THEN                       -- a name taken in a race
        RAISE EXCEPTION 'CATEGORY_NAME_TAKEN' USING ERRCODE = 'P0001';
    WHEN check_violation OR not_null_violation OR invalid_text_representation THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: category' USING ERRCODE = 'P0001';
END;
$$;

-- 5. Writes: archive and restore -------------------------------------------------------------------
-- Archive refuses while active child categories exist, or while active products are in it and no
-- move target is given (CATEGORY_IN_USE with DETAIL {"active_products": n, "active_children": m}).
-- With p_move_to every active product moves first and the archive happens in the SAME transaction;
-- archived products never block. Restore is refused under an archived parent.

CREATE FUNCTION public.set_category_archived(p_id uuid, p_archived boolean, p_move_to uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_cat public.categories%ROWTYPE; v_target public.categories%ROWTYPE;
    v_children integer; v_products integer; v_moved integer := 0; v_after jsonb;
BEGIN
    v_emp := app.require_permission('catalog.manage');
    v_org := app.current_org_id();
    IF p_archived IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: archived' USING ERRCODE = 'P0001';
    END IF;
    SELECT * INTO v_cat FROM public.categories
    WHERE id = p_id AND organization_id = v_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF (v_cat.archived_at IS NOT NULL) = p_archived THEN
        RETURN;                                     -- same state: nothing, no audit row
    END IF;

    IF NOT p_archived THEN                          -- restore
        IF v_cat.parent_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.categories pc
            WHERE pc.id = v_cat.parent_id AND pc.organization_id = v_org
              AND pc.archived_at IS NOT NULL) THEN
            RAISE EXCEPTION 'CATEGORY_PARENT_ARCHIVED' USING ERRCODE = 'P0001';
        END IF;
        UPDATE public.categories SET archived_at = NULL, updated_by = v_emp WHERE id = p_id;
        PERFORM app.write_audit('category.restored', 'category', p_id,
            p_before => app.category_json(v_cat),
            p_after => (SELECT app.category_json(x) FROM public.categories x WHERE x.id = p_id));
        RETURN;
    END IF;

    SELECT count(*)::integer INTO v_children FROM public.categories cc
    WHERE cc.parent_id = p_id AND cc.organization_id = v_org AND cc.archived_at IS NULL;
    SELECT count(*)::integer INTO v_products FROM public.products p
    WHERE p.category_id = p_id AND p.organization_id = v_org AND p.archived_at IS NULL;

    IF v_children > 0 THEN                          -- move them or archive them first
        RAISE EXCEPTION 'CATEGORY_IN_USE' USING ERRCODE = 'P0001',
            DETAIL = format('{"active_products": %s, "active_children": %s}', v_products, v_children);
    END IF;

    IF v_products > 0 AND p_move_to IS NULL THEN
        RAISE EXCEPTION 'CATEGORY_IN_USE' USING ERRCODE = 'P0001',
            DETAIL = format('{"active_products": %s, "active_children": %s}', v_products, v_children);
    END IF;

    IF v_products > 0 THEN                          -- move the active products, then archive
        SELECT * INTO v_target FROM public.categories
        WHERE id = p_move_to AND organization_id = v_org FOR UPDATE;
        IF NOT FOUND OR v_target.id = p_id THEN
            RAISE EXCEPTION 'CATEGORY_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF v_target.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'CATEGORY_PARENT_ARCHIVED' USING ERRCODE = 'P0001';
        END IF;
        UPDATE public.products SET category_id = p_move_to
        WHERE organization_id = v_org AND category_id = p_id AND archived_at IS NULL;
        GET DIAGNOSTICS v_moved = ROW_COUNT;
    END IF;

    UPDATE public.categories SET archived_at = now(), updated_by = v_emp WHERE id = p_id;
    SELECT app.category_json(x) INTO v_after FROM public.categories x WHERE x.id = p_id;
    IF v_products > 0 THEN
        v_after := v_after || jsonb_build_object('moved_products', v_moved, 'moved_to', p_move_to);
    END IF;
    PERFORM app.write_audit('category.archived', 'category', p_id,
        p_before => app.category_json(v_cat), p_after => v_after, p_severity => 'warning');
END;
$$;

REVOKE ALL ON FUNCTION public.list_categories(), public.create_category(text, uuid),
    public.update_category(uuid, jsonb), public.set_category_archived(uuid, boolean, uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.list_categories(), public.create_category(text, uuid),
    public.update_category(uuid, jsonb), public.set_category_archived(uuid, boolean, uuid)
    TO authenticated;

-- 6. The filter helper (the slice's "Done when") --------------------------------------------------
-- STABLE, SECURITY DEFINER, no grants: later slices call it from inside their own functions or
-- tests and filter with  category_id = ANY(app.category_with_children(org, :id))  (D42).
-- Parent + its children in that shop; unknown id or another shop's id -> empty array.

CREATE FUNCTION app.category_with_children(p_org uuid, p_category_id uuid)
RETURNS uuid[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT COALESCE(array_agg(c.id ORDER BY (c.id = p_category_id) DESC, c.name), ARRAY[]::uuid[])
    FROM public.categories c
    WHERE c.organization_id = p_org
      AND (c.id = p_category_id OR c.parent_id = p_category_id)
$$;
REVOKE ALL ON FUNCTION app.category_with_children(uuid, uuid) FROM PUBLIC, anon, authenticated;
