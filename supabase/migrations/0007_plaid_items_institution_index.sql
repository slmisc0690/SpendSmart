-- Speeds up "does this user already have this institution connected" lookups
-- (exchange-public-token's duplicate-Item detection, added alongside this migration) — deliberately
-- a plain index, NOT a unique constraint. A user can legitimately have more than one Item for the
-- same institution (e.g. two different logins/accounts at the same bank), and Plaid's own guidance
-- on duplicate-Item detection is about warning the user and letting them choose, never about making
-- a second legitimate Item impossible to create.

create index if not exists plaid_items_user_institution_idx
  on public.plaid_items (user_id, institution_id);
