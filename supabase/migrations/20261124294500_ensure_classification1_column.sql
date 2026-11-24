-- Ensure the Classification 1 column exists before the daily revenue
-- pulse function references it. This is safe to run even if the
-- two-level-classification migration has already been applied.
alter table public.revenue_classification_rules
  add column if not exists classification1 text;

comment on column public.revenue_classification_rules.classification1
  is 'Broad revenue category used as a fallback for executive reporting.';
