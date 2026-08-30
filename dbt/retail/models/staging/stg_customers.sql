{{ config(materialized='view') }}

-- Type coercion and renaming only.
--
-- The staging layer deliberately does NOT clean the seeded defects: duplicate
-- ids, missing emails and inconsistent country codes all survive into this
-- model so the tests attached to it have something to find. Cleaning happens
-- one layer up, in the marts.

with source as (

    select * from {{ source('airbyte_raw', 'customers') }}

),

renamed as (

    select
        customer_id,
        first_name,
        last_name,
        email,
        phone,
        city,

        -- Left exactly as received. DQ-03 seeds four spellings of the same
        -- country here and the accepted_values test reports each of them.
        country,

        cast(signup_date as date)                       as signup_date,
        loyalty_tier,

        cast(_airbyte_extracted_at as timestamp)        as extracted_at,
        _ab_source_file_url                             as source_file,
        cast(_ab_source_file_last_modified as timestamp) as source_file_modified_at

    from source

)

select * from renamed
