-- =============================================================================
-- I03 · Branch transfers (EC-49, D49)
--
-- Moves stock between branches with a clear trail. Tables are in the baseline (stock_transfers,
-- stock_transfer_lines); this adds the write and read functions. No table changes.
--
-- draft  -> sent      (stock.transfer_send, caller works in the source branch): every line posts a
--                     transfer_out at the source; the stock shows as in transit at the destination
--                     (I01 / v_stock_in_transit: lines of 'sent' transfers). A unit becomes in_transit.
-- sent   -> received  (stock.transfer_receive, caller works in the destination branch): every line
--           or partially_received
--                     posts a transfer_in of the FULL quantity sent at the destination, then what
--                     did not arrive or arrived damaged is written off there by an adjustment with
--                     its reason (loss or damage; one adjustment per reason, numbered SA). So stock
--                     is never in both branches or in neither: it is at the source, in transit, or
--                     at the destination, and a shortage leaves an adjustment document behind.
-- draft  -> cancelled (no stock moved). A sent transfer can't be cancelled; receive it (with
--                     shortages) or send the goods back with a new transfer.
-- Numbered TR in the source branch (F11). Create takes the idempotency key; send, receive and
-- cancel are state changes under a row lock, so a repeat answers the current transfer and moves
-- nothing again (the receipt adjustments use the keys 'system:transfer/<id>/<reason>').
-- Security review (two fixes, section 0): keys starting with 'system:' are reserved for documents
-- the database makes itself (a client could otherwise pre-empt or spoof a receipt adjustment), and
-- a unit leaves a branch only when it is in_stock there: a reserved unit (S10) is refused by
-- send and by every adjustment line, since the ledger trigger alone would let it go.
-- Reads (stock.view): transfers whose source or destination the caller can access; also in an
-- expired (read-only) shop. Numbered after the newest migration on main (D39).
-- =============================================================================

-- 0. Security review fixes (redefine F10 / I02 helpers) ----------------------------------------------

-- F10 + reserved prefix: 'system:' keys belong to documents the database creates itself.
CREATE OR REPLACE FUNCTION app.lock_idempotency_key(p_organization_id uuid, p_key text)
RETURNS void LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
    IF p_key IS NULL OR length(p_key) NOT BETWEEN 8 AND 128 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: the idempotency key must be 8 to 128 characters' USING ERRCODE = 'P0001';
    END IF;
    IF p_key LIKE 'system:%' THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: idempotency keys starting with system: are reserved' USING ERRCODE = 'P0001';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('idempotency/' || p_organization_id::text || '/' || p_key, 0));
END;
$$;

-- I02 + a unit leaves only when it is in stock in that branch (locked): a reserved unit is
-- refused (its reservation is released first, S10), as is a unit of another branch.
CREATE OR REPLACE FUNCTION app.post_adjustment_lines(p_org uuid, p_emp uuid, p_adjustment_id uuid, p_branch_id uuid,
                                                     p_lines jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE r record; v_line uuid;
BEGIN
    FOR r IN
        SELECT (e ->> 'product_id')::uuid AS product_id, NULLIF(e ->> 'unit_id', '')::uuid AS unit_id,
               (e ->> 'quantity')::integer AS quantity
        FROM jsonb_array_elements(p_lines) e
        ORDER BY 1, 2 NULLS FIRST
    LOOP
        IF r.unit_id IS NOT NULL AND r.quantity > 0 AND NOT EXISTS (
            SELECT 1 FROM public.units u
            WHERE u.id = r.unit_id AND u.organization_id = p_org AND u.status = 'written_off') THEN
            RAISE EXCEPTION 'UNIT_NOT_AVAILABLE: only a written-off unit can be found again' USING ERRCODE = 'P0001';
        END IF;
        IF r.unit_id IS NOT NULL AND r.quantity < 0 AND NOT EXISTS (
            SELECT 1 FROM public.units u
            WHERE u.id = r.unit_id AND u.organization_id = p_org AND u.branch_id = p_branch_id
              AND u.status = 'in_stock' FOR UPDATE) THEN
            RAISE EXCEPTION 'UNIT_NOT_AVAILABLE: the unit is not in stock here (reserved units are released first)'
                USING ERRCODE = 'P0001';
        END IF;
        INSERT INTO public.stock_adjustment_lines (organization_id, adjustment_id, product_id, unit_id, quantity, created_by)
        VALUES (p_org, p_adjustment_id, r.product_id, r.unit_id, r.quantity, p_emp)
        RETURNING id INTO v_line;
        INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type,
                                            stock_state, unit_cost, source_type, source_id, source_line_id, created_by)
        SELECT p_org, r.product_id, p_branch_id, r.unit_id, r.quantity, 'adjustment', 'sellable',
               COALESCE(u.cost, p.avg_cost, 0), 'stock_adjustment', p_adjustment_id, v_line, p_emp
        FROM public.products p
        LEFT JOIN public.units u ON u.id = r.unit_id AND u.organization_id = p_org
        WHERE p.id = r.product_id AND p.organization_id = p_org;
    END LOOP;
END;
$$;

-- 1. JSON for the API --------------------------------------------------------------------------------

CREATE FUNCTION app.stock_transfer_json(p_org uuid, p_id uuid, p_with_lines boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
    SELECT jsonb_build_object(
        'id', t.id, 'number', t.number, 'from_branch_id', t.from_branch_id, 'to_branch_id', t.to_branch_id,
        -- Names too: a receiver may not work in the source branch (GET /api/branches lists theirs only).
        'from_branch_name', fb.name, 'to_branch_name', tb.name,
        'status', t.status, 'notes', t.notes, 'created_at', t.created_at, 'created_by_name', ce.full_name,
        'sent_at', t.sent_at, 'sent_by_name', se.full_name,
        'received_at', t.received_at, 'received_by_name', re.full_name,
        'lines_count', (SELECT count(*) FROM public.stock_transfer_lines l
                        WHERE l.organization_id = p_org AND l.transfer_id = t.id),
        'quantity_sent', (SELECT COALESCE(sum(l.qty_sent), 0) FROM public.stock_transfer_lines l
                          WHERE l.organization_id = p_org AND l.transfer_id = t.id),
        'quantity_received', (SELECT sum(l.qty_received) FROM public.stock_transfer_lines l
                              WHERE l.organization_id = p_org AND l.transfer_id = t.id),
        'adjustments', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', a.id, 'number', a.number, 'reason', a.reason)
                             ORDER BY a.number)
            FROM public.stock_adjustments a
            WHERE a.organization_id = p_org AND a.idempotency_key LIKE 'system:transfer/' || t.id::text || '/%'),
            '[]'::jsonb))
        || CASE WHEN p_with_lines THEN jsonb_build_object('lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', l.id, 'product_id', l.product_id, 'name_ar', p.name_ar, 'name_en', p.name_en,
                'sku', p.sku, 'is_serialized', p.is_serialized, 'unit_id', l.unit_id, 'serial', u.serial,
                'qty_sent', l.qty_sent, 'qty_received', l.qty_received,
                'discrepancy_reason', l.discrepancy_reason)
                ORDER BY p.name_ar, l.product_id, u.serial NULLS FIRST, l.id)
            FROM public.stock_transfer_lines l
            JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
            LEFT JOIN public.units u ON u.id = l.unit_id AND u.organization_id = l.organization_id
            WHERE l.organization_id = p_org AND l.transfer_id = t.id), '[]'::jsonb))
           ELSE '{}'::jsonb END
    FROM public.stock_transfers t
    JOIN public.branches fb ON fb.id = t.from_branch_id AND fb.organization_id = t.organization_id
    JOIN public.branches tb ON tb.id = t.to_branch_id AND tb.organization_id = t.organization_id
    LEFT JOIN public.employees ce ON ce.id = t.created_by AND ce.organization_id = t.organization_id
    LEFT JOIN public.employees se ON se.id = t.sent_by AND se.organization_id = t.organization_id
    LEFT JOIN public.employees re ON re.id = t.received_by AND re.organization_id = t.organization_id
    WHERE t.organization_id = p_org AND t.id = p_id
$$;

-- 2. Draft lines -----------------------------------------------------------------------------------

-- Checks and stores the lines of a draft (replacing any old ones): [{product_id, unit_id?, quantity}]
-- with quantity > 0; a serialized product needs a unit in stock in the source branch (quantity 1).
CREATE FUNCTION app.set_transfer_lines(p_org uuid, p_emp uuid, p_transfer public.stock_transfers, p_lines jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_lines jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('product_id', x.product_id, 'unit_id', x.unit_id, 'quantity', x.qty))
    INTO v_lines FROM app.stock_lines_parse(p_lines, 'adjust') x;

    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               WHERE l.quantity IS NULL OR l.quantity < 1 OR l.quantity > 1000000)
       OR EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
                  GROUP BY l.product_id, l.unit_id HAVING count(*) > 1) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               WHERE NOT EXISTS (SELECT 1 FROM public.products p
                                 WHERE p.id = l.product_id AND p.organization_id = p_org)) THEN
        RAISE EXCEPTION 'PRODUCT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               JOIN public.products p ON p.id = l.product_id AND p.organization_id = p_org
               WHERE p.is_serialized AND l.unit_id IS NULL) THEN
        RAISE EXCEPTION 'UNIT_REQUIRED' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               JOIN public.products p ON p.id = l.product_id AND p.organization_id = p_org
               WHERE NOT p.is_serialized AND l.unit_id IS NOT NULL) THEN
        RAISE EXCEPTION 'UNIT_NOT_ALLOWED' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               WHERE l.unit_id IS NOT NULL AND NOT EXISTS (
                   SELECT 1 FROM public.units u WHERE u.id = l.unit_id AND u.organization_id = p_org)) THEN
        RAISE EXCEPTION 'UNIT_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               JOIN public.units u ON u.id = l.unit_id AND u.organization_id = p_org
               WHERE u.product_id <> l.product_id) THEN
        RAISE EXCEPTION 'UNIT_PRODUCT_MISMATCH' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               WHERE l.unit_id IS NOT NULL AND l.quantity <> 1) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer)
               JOIN public.units u ON u.id = l.unit_id AND u.organization_id = p_org
               WHERE u.branch_id <> p_transfer.from_branch_id OR u.status <> 'in_stock') THEN
        RAISE EXCEPTION 'UNIT_NOT_AVAILABLE: a unit is not in stock in the source branch' USING ERRCODE = 'P0001';
    END IF;

    DELETE FROM public.stock_transfer_lines l WHERE l.organization_id = p_org AND l.transfer_id = p_transfer.id;
    INSERT INTO public.stock_transfer_lines (organization_id, transfer_id, product_id, unit_id, qty_sent, created_by)
    SELECT p_org, p_transfer.id, l.product_id, l.unit_id, l.quantity, p_emp
    FROM jsonb_to_recordset(v_lines) l(product_id uuid, unit_id uuid, quantity integer);
END;
$$;

-- Loads a transfer for a write: the caller's shop, locked.
CREATE FUNCTION app.stock_transfer_for_write(p_org uuid, p_id uuid)
RETURNS public.stock_transfers LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_t public.stock_transfers;
BEGIN
    SELECT * INTO v_t FROM public.stock_transfers t WHERE t.id = p_id AND t.organization_id = p_org FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    RETURN v_t;
END;
$$;

-- 3. Writes ----------------------------------------------------------------------------------------

CREATE FUNCTION public.create_stock_transfer(p_from_branch_id uuid, p_to_branch_id uuid, p_notes text,
                                             p_lines jsonb, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_t public.stock_transfers; v_notes text;
BEGIN
    v_emp := app.require_permission('stock.transfer_send');
    v_org := app.current_org_id();
    PERFORM app.lock_idempotency_key(v_org, p_idempotency_key);
    SELECT * INTO v_t FROM public.stock_transfers t
    WHERE t.organization_id = v_org AND t.idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN app.stock_transfer_json(v_org, v_t.id, true);     -- a repeat changes nothing
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_from_branch_id AND b.organization_id = v_org)
       OR NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_to_branch_id AND b.organization_id = v_org) THEN
        RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF p_from_branch_id = p_to_branch_id THEN
        RAISE EXCEPTION 'TRANSFER_SAME_BRANCH' USING ERRCODE = 'P0001';
    END IF;
    PERFORM app.require_branch_access(p_from_branch_id);
    IF EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_to_branch_id AND NOT b.is_active) THEN
        RAISE EXCEPTION 'BRANCH_INACTIVE: %', p_to_branch_id USING ERRCODE = '42501';
    END IF;
    v_notes := NULLIF(btrim(p_notes), '');
    IF length(v_notes) > 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: notes' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.stock_transfers (organization_id, number, from_branch_id, to_branch_id, notes,
                                        idempotency_key, created_by, updated_by)
    VALUES (v_org, app.next_document_number(v_org, p_from_branch_id, 'transfer'), p_from_branch_id,
            p_to_branch_id, v_notes, p_idempotency_key, v_emp, v_emp)
    RETURNING * INTO v_t;
    PERFORM app.set_transfer_lines(v_org, v_emp, v_t, p_lines);

    PERFORM app.write_audit('stock_transfer.created', 'stock_transfer', v_t.id, NULL,
        jsonb_build_object('number', v_t.number, 'to_branch_id', p_to_branch_id, 'lines', p_lines),
        NULL, p_from_branch_id);
    RETURN app.stock_transfer_json(v_org, v_t.id, true);
END;
$$;

-- Replaces the notes and lines of a draft.
CREATE FUNCTION public.update_stock_transfer(p_id uuid, p_notes text, p_lines jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_t public.stock_transfers; v_notes text;
BEGIN
    v_emp := app.require_permission('stock.transfer_send');
    v_org := app.current_org_id();
    v_t := app.stock_transfer_for_write(v_org, p_id);
    PERFORM app.require_branch_access(v_t.from_branch_id);
    IF v_t.status IN ('sent', 'received', 'partially_received') THEN
        RAISE EXCEPTION 'TRANSFER_ALREADY_SENT' USING ERRCODE = 'P0001';
    ELSIF v_t.status <> 'draft' THEN
        RAISE EXCEPTION 'DOCUMENT_FINAL: the transfer is %', v_t.status USING ERRCODE = 'P0001';
    END IF;
    v_notes := NULLIF(btrim(p_notes), '');
    IF length(v_notes) > 500 THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: notes' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.stock_transfers t SET notes = v_notes, updated_by = v_emp WHERE t.id = p_id;
    PERFORM app.set_transfer_lines(v_org, v_emp, v_t, p_lines);
    PERFORM app.write_audit('stock_transfer.updated', 'stock_transfer', p_id, NULL,
        jsonb_build_object('number', v_t.number, 'notes', v_notes, 'lines', p_lines), NULL, v_t.from_branch_id);
    RETURN app.stock_transfer_json(v_org, p_id, true);
END;
$$;

-- Sends a draft: the stock leaves the source branch (transfer_out) and is in transit.
CREATE FUNCTION public.send_stock_transfer(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_t public.stock_transfers;
BEGIN
    v_emp := app.require_permission('stock.transfer_send');
    v_org := app.current_org_id();
    v_t := app.stock_transfer_for_write(v_org, p_id);
    PERFORM app.require_branch_access(v_t.from_branch_id);
    IF v_t.status IN ('sent', 'received', 'partially_received') THEN
        RETURN app.stock_transfer_json(v_org, p_id, true);       -- a repeat moves nothing again
    ELSIF v_t.status <> 'draft' THEN
        RAISE EXCEPTION 'DOCUMENT_FINAL: the transfer is %', v_t.status USING ERRCODE = 'P0001';
    END IF;
    IF EXISTS (SELECT 1 FROM public.branches b WHERE b.id = v_t.to_branch_id AND NOT b.is_active) THEN
        RAISE EXCEPTION 'BRANCH_INACTIVE: %', v_t.to_branch_id USING ERRCODE = '42501';
    END IF;
    -- The units again, now and locked: the draft was checked when saved. A reserved unit stays.
    PERFORM 1 FROM public.units u
    WHERE u.organization_id = v_org
      AND u.id IN (SELECT l.unit_id FROM public.stock_transfer_lines l
                   WHERE l.organization_id = v_org AND l.transfer_id = p_id AND l.unit_id IS NOT NULL)
    ORDER BY u.id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM public.stock_transfer_lines l
               JOIN public.units u ON u.id = l.unit_id AND u.organization_id = l.organization_id
               WHERE l.organization_id = v_org AND l.transfer_id = p_id
                 AND (u.branch_id <> v_t.from_branch_id OR u.status <> 'in_stock')) THEN
        RAISE EXCEPTION 'UNIT_NOT_AVAILABLE: a unit is no longer in stock in the source branch' USING ERRCODE = 'P0001';
    END IF;

    -- Product, then unit order: two documents lock stock rows in the same order.
    INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type,
                                        stock_state, unit_cost, source_type, source_id, source_line_id, created_by)
    SELECT v_org, l.product_id, v_t.from_branch_id, l.unit_id, -l.qty_sent, 'transfer_out', 'sellable',
           COALESCE(u.cost, p.avg_cost, 0), 'transfer', p_id, l.id, v_emp
    FROM public.stock_transfer_lines l
    JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
    LEFT JOIN public.units u ON u.id = l.unit_id AND u.organization_id = l.organization_id
    WHERE l.organization_id = v_org AND l.transfer_id = p_id
    ORDER BY l.product_id, l.unit_id NULLS FIRST;

    UPDATE public.stock_transfers t
       SET status = 'sent', sent_at = now(), sent_by = v_emp, updated_by = v_emp
     WHERE t.id = p_id;
    PERFORM app.write_audit('stock_transfer.sent', 'stock_transfer', p_id,
        jsonb_build_object('status', 'draft'), jsonb_build_object('status', 'sent', 'number', v_t.number),
        NULL, v_t.from_branch_id);
    RETURN app.stock_transfer_json(v_org, p_id, true);
END;
$$;

-- Receives a sent transfer at the destination. p_lines lists only what did not arrive in full:
-- [{line_id, qty_received, reason: 'loss' | 'damage'}]; every other line arrived complete.
CREATE FUNCTION public.receive_stock_transfer(p_id uuid, p_lines jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid; v_org uuid; v_t public.stock_transfers; v_short jsonb; v_adj uuid; r record;
    v_reason text; v_lines jsonb;
BEGIN
    v_emp := app.require_permission('stock.transfer_receive');
    v_org := app.current_org_id();
    v_t := app.stock_transfer_for_write(v_org, p_id);
    PERFORM app.require_branch_access(v_t.to_branch_id);
    IF v_t.status IN ('received', 'partially_received') THEN
        RETURN app.stock_transfer_json(v_org, p_id, true);       -- a repeat moves nothing again
    ELSIF v_t.status = 'draft' THEN
        RAISE EXCEPTION 'TRANSFER_NOT_SENT' USING ERRCODE = 'P0001';
    ELSIF v_t.status <> 'sent' THEN
        RAISE EXCEPTION 'DOCUMENT_FINAL: the transfer is %', v_t.status USING ERRCODE = 'P0001';
    END IF;

    -- The shortages, checked against the transfer's own lines.
    IF p_lines IS NULL THEN
        p_lines := '[]'::jsonb;
    END IF;
    IF jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) > 500
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_lines) e
                  WHERE jsonb_typeof(e) <> 'object'
                     OR EXISTS (SELECT 1 FROM jsonb_object_keys(e) k WHERE k NOT IN ('line_id', 'qty_received', 'reason'))
                     OR jsonb_typeof(e -> 'line_id') IS DISTINCT FROM 'string'
                     OR jsonb_typeof(e -> 'qty_received') IS DISTINCT FROM 'number'
                     OR COALESCE(e ->> 'reason', '') NOT IN ('loss', 'damage')) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;
    BEGIN
        SELECT jsonb_agg(jsonb_build_object('line_id', (e ->> 'line_id')::uuid,
                                            'qty_received', (e ->> 'qty_received')::integer,
                                            'reason', e ->> 'reason'))
        INTO v_short FROM jsonb_array_elements(p_lines) e;
    EXCEPTION WHEN others THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END;
    v_short := COALESCE(v_short, '[]'::jsonb);
    IF EXISTS (SELECT 1 FROM jsonb_to_recordset(v_short) s(line_id uuid, qty_received integer, reason text)
               GROUP BY s.line_id HAVING count(*) > 1)
       OR EXISTS (SELECT 1 FROM jsonb_to_recordset(v_short) s(line_id uuid, qty_received integer, reason text)
                  LEFT JOIN public.stock_transfer_lines l
                         ON l.id = s.line_id AND l.organization_id = v_org AND l.transfer_id = p_id
                  WHERE l.id IS NULL OR s.qty_received < 0 OR s.qty_received >= l.qty_sent) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: lines' USING ERRCODE = 'P0001';
    END IF;

    UPDATE public.stock_transfer_lines l
       SET qty_received = COALESCE(s.qty_received, l.qty_sent), discrepancy_reason = s.reason
      FROM public.stock_transfer_lines l2
      LEFT JOIN jsonb_to_recordset(v_short) s(line_id uuid, qty_received integer, reason text) ON s.line_id = l2.id
     WHERE l.id = l2.id AND l2.organization_id = v_org AND l2.transfer_id = p_id;

    -- Everything sent enters the destination (product, then unit order) ...
    INSERT INTO public.stock_movements (organization_id, product_id, branch_id, unit_id, quantity, type,
                                        stock_state, unit_cost, source_type, source_id, source_line_id, created_by)
    SELECT v_org, l.product_id, v_t.to_branch_id, l.unit_id, l.qty_sent, 'transfer_in', 'sellable',
           COALESCE(u.cost, p.avg_cost, 0), 'transfer', p_id, l.id, v_emp
    FROM public.stock_transfer_lines l
    JOIN public.products p ON p.id = l.product_id AND p.organization_id = l.organization_id
    LEFT JOIN public.units u ON u.id = l.unit_id AND u.organization_id = l.organization_id
    WHERE l.organization_id = v_org AND l.transfer_id = p_id
    ORDER BY l.product_id, l.unit_id NULLS FIRST;

    -- ... and what is missing or damaged is written off there, one adjustment per reason.
    FOREACH v_reason IN ARRAY ARRAY['damage', 'loss'] LOOP
        SELECT jsonb_agg(jsonb_build_object('product_id', l.product_id, 'unit_id', l.unit_id,
                                            'quantity', l.qty_received - l.qty_sent))
        INTO v_lines
        FROM public.stock_transfer_lines l
        WHERE l.organization_id = v_org AND l.transfer_id = p_id AND l.discrepancy_reason = v_reason;
        CONTINUE WHEN v_lines IS NULL;
        INSERT INTO public.stock_adjustments (organization_id, number, branch_id, reason, note, idempotency_key, created_by)
        VALUES (v_org, app.next_document_number(v_org, v_t.to_branch_id, 'stock_adjustment'), v_t.to_branch_id,
                v_reason::public.adjustment_reason, 'Transfer ' || v_t.number,
                'system:transfer/' || p_id::text || '/' || v_reason, v_emp)
        RETURNING id INTO v_adj;
        PERFORM app.post_adjustment_lines(v_org, v_emp, v_adj, v_t.to_branch_id, v_lines);
    END LOOP;

    UPDATE public.stock_transfers t
       SET status = CASE WHEN jsonb_array_length(v_short) > 0 THEN 'partially_received' ELSE 'received' END::public.transfer_status,
           received_at = now(), received_by = v_emp, updated_by = v_emp
     WHERE t.id = p_id;
    PERFORM app.write_audit('stock_transfer.received', 'stock_transfer', p_id,
        jsonb_build_object('status', 'sent'),
        jsonb_build_object('status', CASE WHEN jsonb_array_length(v_short) > 0 THEN 'partially_received' ELSE 'received' END,
                           'number', v_t.number, 'discrepancies', v_short),
        NULL, v_t.to_branch_id);
    RETURN app.stock_transfer_json(v_org, p_id, true);
END;
$$;

-- Cancels a draft (nothing moved). A sent transfer is received instead (with shortages).
CREATE FUNCTION public.cancel_stock_transfer(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_emp uuid; v_org uuid; v_t public.stock_transfers;
BEGIN
    v_emp := app.require_permission('stock.transfer_send');
    v_org := app.current_org_id();
    v_t := app.stock_transfer_for_write(v_org, p_id);
    PERFORM app.require_branch_access(v_t.from_branch_id);
    IF v_t.status = 'cancelled' THEN
        RETURN app.stock_transfer_json(v_org, p_id, true);
    ELSIF v_t.status IN ('sent', 'received', 'partially_received') THEN
        RAISE EXCEPTION 'TRANSFER_ALREADY_SENT' USING ERRCODE = 'P0001';
    END IF;
    UPDATE public.stock_transfers t SET status = 'cancelled', updated_by = v_emp WHERE t.id = p_id;
    PERFORM app.write_audit('stock_transfer.cancelled', 'stock_transfer', p_id,
        jsonb_build_object('status', 'draft'), jsonb_build_object('status', 'cancelled', 'number', v_t.number),
        NULL, v_t.from_branch_id);
    RETURN app.stock_transfer_json(v_org, p_id, true);
END;
$$;

-- 4. Reads -----------------------------------------------------------------------------------------

-- Transfers whose source or destination the caller can access (p_branch_id: either side), newest first.
CREATE FUNCTION public.list_stock_transfers(p_branch_id uuid DEFAULT NULL, p_status text DEFAULT NULL,
                                            p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_branches uuid[]; v_result jsonb;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100 OR p_offset IS NULL OR p_offset < 0
       OR (p_status IS NOT NULL AND p_status NOT IN ('draft', 'sent', 'received', 'partially_received', 'cancelled')) THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: list' USING ERRCODE = 'P0001';
    END IF;
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.branches b WHERE b.id = p_branch_id AND b.organization_id = v_org) THEN
            RAISE EXCEPTION 'BRANCH_NOT_FOUND' USING ERRCODE = 'P0001';
        END IF;
        IF NOT app.has_branch_access(p_branch_id) THEN
            RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
        END IF;
        v_branches := ARRAY[p_branch_id];
    ELSE
        SELECT COALESCE(array_agg(b.id), ARRAY[]::uuid[]) INTO v_branches
        FROM public.branches b WHERE b.organization_id = v_org AND app.has_branch_access(b.id);
    END IF;

    WITH found AS (
        SELECT t.id, t.created_at FROM public.stock_transfers t
        WHERE t.organization_id = v_org
          AND (t.from_branch_id = ANY(v_branches) OR t.to_branch_id = ANY(v_branches))
          AND (p_status IS NULL OR t.status::text = p_status)
    )
    SELECT jsonb_build_object(
        'items', COALESCE((
            SELECT jsonb_agg(app.stock_transfer_json(v_org, f.id, false) ORDER BY f.created_at DESC, f.id DESC)
            FROM (SELECT * FROM found ORDER BY created_at DESC, id DESC LIMIT p_limit OFFSET p_offset) f),
            '[]'::jsonb),
        'total', (SELECT count(*) FROM found))
    INTO v_result;
    RETURN v_result;
END;
$$;

CREATE FUNCTION public.get_stock_transfer(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
DECLARE v_org uuid; v_t public.stock_transfers;
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.view') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.view' USING ERRCODE = '42501';
    END IF;
    v_org := app.current_org_id();
    SELECT * INTO v_t FROM public.stock_transfers t WHERE t.id = p_id AND t.organization_id = v_org;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'STOCK_TRANSFER_NOT_FOUND' USING ERRCODE = 'P0001';
    END IF;
    IF NOT (app.has_branch_access(v_t.from_branch_id) OR app.has_branch_access(v_t.to_branch_id)) THEN
        RAISE EXCEPTION 'BRANCH_DENIED' USING ERRCODE = '42501';
    END IF;
    RETURN app.stock_transfer_json(v_org, p_id, true);
END;
$$;

-- Where a transfer can go: every active branch of the shop (id, code, name). A sender works in
-- some branches only, but sends to any of them. Names only; stock.transfer_send.
CREATE FUNCTION public.list_transfer_destinations()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    IF app.current_employee_id() IS NULL THEN
        RAISE EXCEPTION 'NOT_AN_EMPLOYEE' USING ERRCODE = '42501';
    END IF;
    IF NOT app.has_permission('stock.transfer_send') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED: stock.transfer_send' USING ERRCODE = '42501';
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', b.id, 'code', b.code, 'name', b.name)
                         ORDER BY b.is_main DESC, b.code)
        FROM public.branches b
        WHERE b.organization_id = app.current_org_id() AND b.is_active AND b.archived_at IS NULL), '[]'::jsonb);
END;
$$;

-- 5. Grants ----------------------------------------------------------------------------------------

REVOKE ALL ON FUNCTION app.stock_transfer_json(uuid, uuid, boolean),
    app.set_transfer_lines(uuid, uuid, public.stock_transfers, jsonb),
    app.stock_transfer_for_write(uuid, uuid)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_stock_transfer(uuid, uuid, text, jsonb, text),
    public.update_stock_transfer(uuid, text, jsonb), public.send_stock_transfer(uuid),
    public.receive_stock_transfer(uuid, jsonb), public.cancel_stock_transfer(uuid),
    public.list_stock_transfers(uuid, text, integer, integer), public.get_stock_transfer(uuid),
    public.list_transfer_destinations()
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_stock_transfer(uuid, uuid, text, jsonb, text),
    public.update_stock_transfer(uuid, text, jsonb), public.send_stock_transfer(uuid),
    public.receive_stock_transfer(uuid, jsonb), public.cancel_stock_transfer(uuid),
    public.list_stock_transfers(uuid, text, integer, integer), public.get_stock_transfer(uuid),
    public.list_transfer_destinations()
    TO authenticated;
