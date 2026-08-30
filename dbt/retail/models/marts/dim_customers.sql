{{ config(materialized='table') }}

-- Curated customer dimension.
--
-- This is where the seeded defects finally get handled. Staging preserved them
-- so the tests could find them; the mart resolves them so downstream consumers
-- get one row per customer with a normalised country code.
--
-- The contrast is the point: retail_staging.stg_customers is what arrived,
-- retail_marts.dim_customers is what is safe to build on, and the dbt warnings
-- are the record of the difference.

with staged as (

    select * from {{ ref('stg_customers') }}

),

deduplicated as (

    -- DQ-01: keep the most recently extracted record per customer. Ties break
    -- on source file name so the result is stable across runs rather than
    -- depending on scan order.
    select
        *,
        row_number() over (
            partition by customer_id
            order by extracted_at desc, source_file desc
        ) as _row_number

    from staged

),

cleaned as (

    select
        customer_id,
        first_name,
        last_name,
        first_name || ' ' || last_name                  as full_name,

        -- DQ-02: absent rather than empty, so consumers can distinguish
        -- "no email on file" from "email is the empty string".
        email,
        email is not null                               as has_email,

        phone,
        city,

        -- DQ-03: fold the four spellings onto the ISO alpha-2 code. Anything
        -- still unrecognised is surfaced as 'XX' rather than guessed at.
        case upper(trim(country))
            when 'US' then 'US'
            when 'USA' then 'US'
            when 'UNITED STATES' then 'US'
            when 'CA' then 'CA'
            when 'GB' then 'GB'
            when 'FR' then 'FR'
            when 'DE' then 'DE'
            else 'XX'
        end                                             as country_code,

        -- DQ-04: a signup date in the future is not usable as a fact, so it is
        -- nulled and flagged rather than silently carried forward.
        case
            when signup_date > cast('{{ var("retail_today") }}' as date) then null
            else signup_date
        end                                             as signup_date,
        signup_date > cast('{{ var("retail_today") }}' as date)
                                                        as had_invalid_signup_date,

        loyalty_tier,
        extracted_at,
        source_file

    from deduplicated
    where _row_number = 1

)

select * from cleaned
