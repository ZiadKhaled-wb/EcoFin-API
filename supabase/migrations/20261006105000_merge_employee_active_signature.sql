-- O02 and EC-143 independently introduced the same RPC with different return types.
-- Replace the O02 void signature before the unchanged EC-143 migration creates its table return.
DROP FUNCTION IF EXISTS public.set_employee_active(uuid, boolean, text);
