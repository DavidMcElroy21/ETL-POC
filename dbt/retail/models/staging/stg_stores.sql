{{ config(materialized='view') }}

-- The control group. No defects are seeded into stores, which is what lets the
-- error-severity tests in _staging__models.yml pass and thereby prove that the
-- warn severity used everywhere else is a choice rather than an absence.

with source as (

    select * from {{ source('airbyte_raw', 'stores') }}

),

renamed as (

    select
        store_id,
        store_name,
        city,
        country,
        region,
        cast(opened_date as date)                       as opened_date,
        cast(square_feet as integer)                    as square_feet,

        cast(_airbyte_extracted_at as timestamp)        as extracted_at,
        _ab_source_file_url                             as source_file,
        cast(_ab_source_file_last_modified as timestamp) as source_file_modified_at

    from source

)

select * from renamed
