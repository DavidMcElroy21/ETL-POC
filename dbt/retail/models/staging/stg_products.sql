{{ config(materialized='view') }}

with source as (

    select * from {{ source('airbyte_raw', 'products') }}

),

renamed as (

    select
        product_id,
        product_name,

        -- DQ-06 seeds three products with no category.
        category,
        subcategory,

        -- DQ-05 seeds one negative unit price. Cast, not filtered.
        cast(unit_price as numeric(12, 2))              as unit_price,
        cast(cost_price as numeric(12, 2))              as cost_price,
        supplier,

        cast(_airbyte_extracted_at as timestamp)        as extracted_at,
        _ab_source_file_url                             as source_file,
        cast(_ab_source_file_last_modified as timestamp) as source_file_modified_at

    from source

)

select * from renamed
