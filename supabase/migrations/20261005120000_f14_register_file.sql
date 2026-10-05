-- F14 file storage (EC-33, D36). Migration 20261005120000_f14_register_file.sql.
-- The bytes go to the private bucket `tenant-files` through the API's storage module (service role
-- only). The metadata row is written by this one function, with the caller's own JWT:
--   public.register_file()   records one stored object in public.files and writes one audit row
-- Rows in public.files are never deleted (the baseline blocks it), so there is no delete function.
--
-- Org and employee come from the session (app.current_org_id, app.require_permission), never from
-- a parameter. The permission depends on the purpose; the map below is the same one the API uses
-- (src/services/files.rules.ts, UPLOAD_PERMISSION). The path must sit under the caller's own shop.

CREATE FUNCTION public.register_file(
    p_id          uuid,
    p_path        text,
    p_original_name text,
    p_mime        text,
    p_size_bytes  bigint,
    p_sha256      text,
    p_purpose     public.file_purpose,
    p_entity_type text,
    p_entity_id   uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
    v_emp uuid := app.require_permission(CASE p_purpose
        WHEN 'logo'             THEN 'org.settings_manage'
        WHEN 'product_image'    THEN 'catalog.manage'
        WHEN 'customer_id'      THEN 'customer.edit'
        WHEN 'survey_photo'     THEN 'survey.submit'
        WHEN 'signature'        THEN 'installment.create'
        WHEN 'contract_pdf'     THEN 'installment.create'
        WHEN 'promissory_note'  THEN 'installment.create'
        WHEN 'delivery_proof'   THEN 'delivery.manage'
        WHEN 'expense_receipt'  THEN 'expense.create'
        WHEN 'legal_document'   THEN 'legal.manage'
        WHEN 'import'           THEN 'import.data'
        WHEN 'export'           THEN 'export.data'
        WHEN 'other'            THEN 'org.settings_manage'
    END);
    v_org uuid := app.current_org_id();
BEGIN
    IF p_id IS NULL OR p_path IS NULL OR p_mime IS NULL OR p_size_bytes IS NULL
       OR p_size_bytes < 0 OR p_purpose IS NULL THEN
        RAISE EXCEPTION 'VALIDATION_FAILED: id, path, mime, size and purpose are required'
            USING ERRCODE = 'P0001';
    END IF;

    -- The object must sit under the caller's own shop: '<org id>/...', no '.', '..' or backslash.
    IF left(p_path, length(v_org::text) + 1) <> v_org::text || '/'
       OR p_path ~ '\\' OR p_path ~ '(^|/)\.{1,2}(/|$)' THEN
        RAISE EXCEPTION 'FILE_PATH_INVALID: the path must start with the shop id' USING ERRCODE = 'P0001';
    END IF;

    INSERT INTO public.files (id, organization_id, bucket, path, original_name, mime, size_bytes,
                              sha256, purpose, entity_type, entity_id, created_by)
    VALUES (p_id, v_org, 'tenant-files', p_path, p_original_name, p_mime, p_size_bytes,
            p_sha256, p_purpose, p_entity_type, p_entity_id, v_emp);

    PERFORM app.write_audit('file.upload', 'file', p_id, NULL,
        jsonb_build_object('purpose', p_purpose, 'size', p_size_bytes,
                           'entity_type', p_entity_type, 'entity_id', p_entity_id));
    RETURN p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_file(uuid, text, text, text, bigint, text,
                                               public.file_purpose, text, uuid) TO authenticated;
