{{ config(materialized='view') }}

with source as (

    select * from {{ source('airbyte_raw', 'order_items') }}

),

renamed as (

    select
        order_item_id,

        -- DQ-13 seeds four line items whose parent order does not exist.
        order_id,
        product_id,

        -- DQ-11 seeds a zero and a negative quantity.
        cast(quantity as integer)                       as quantity,
        cast(unit_price as numeric(12, 2))              as unit_price,
        cast(discount_pct as numeric(5, 4))             as discount_pct,

        -- DQ-12 seeds six lines where this disagrees with the arithmetic.
        cast(line_total as numeric(12, 2))              as line_total,

        -- What line_total should be. Materialising the expectation alongside
        -- the reported value keeps the drift test readable and gives anyone
        -- investigating a warning the delta without rewriting the maths.
        round(
            cast(quantity as integer)
            * cast(unit_price as numeric(12, 2))
            * (1 - cast(discount_pct as numeric(5, 4))),
            2
        )                                               as expected_line_total,

        cast(_airbyte_extracted_at as timestamp)        as extracted_at,
        _ab_source_file_url                             as source_file,
        cast(_ab_source_file_last_modified as timestamp) as source_file_modified_at

    from source

)

select * from renamed
