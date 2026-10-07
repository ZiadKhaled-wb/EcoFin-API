-- P03 (D40): shops can also sell on daily installments (carried over from FinTech-Pro).
-- Its own migration: a new enum value can't be used in the transaction that adds it.
ALTER TYPE public.installment_frequency ADD VALUE IF NOT EXISTS 'daily';
