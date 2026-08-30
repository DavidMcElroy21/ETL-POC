{{ config(severity='warn') }}

-- DQ-04: a customer registered on a date that has not happened yet.
--
-- Written as a singular test rather than a generic one because the comparison
-- is against a project variable, and because the failing rows are more useful
-- than a count: whoever investigates wants to see which customer and by how
-- much, not just that something is wrong.
--
-- The reference date is `retail_today` in dbt_project.yml. The sample data is
-- fixed, so this stays deterministic instead of drifting with the wall clock.

select
    customer_id,
    email,
    signup_date,
    cast('{{ var("retail_today") }}' as date) as reference_date,
    signup_date - cast('{{ var("retail_today") }}' as date) as days_in_future,
    source_file

from {{ ref('stg_customers') }}

where signup_date > cast('{{ var("retail_today") }}' as date)
