-- O02 and EC-143 independently introduced the same RPC with different return types.
-- EC-143 (20261006110000) creates the RETURNS TABLE version first; drop it so O02
-- (20261006110400) can create its own, and 20261006120000 then replaces both with the merged one.
-- Renumbered from 20261006105000 (D39): the O01/O02/P01/P05 migrations had to move after EC-143,
-- which was already applied on the development database.
DROP FUNCTION IF EXISTS public.set_employee_active(uuid, boolean, text);
