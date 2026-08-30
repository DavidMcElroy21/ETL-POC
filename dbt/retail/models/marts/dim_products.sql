{{ config(materialized='table') }}

-- Curated product dimension.

with staged as (

    select * from {{ ref('stg_products') }}

),

cleaned as (

    select
        product_id,
        product_name,

        -- DQ-06: an explicit 'Uncategorised' bucket beats a NULL that every
        -- downstream join has to remember to handle.
        coalesce(category, 'Uncategorised')             as category,
        category is null                                as is_uncategorised,
        subcategory,

        -- DQ-05: a negative price is not a discount, it is a data error. Null
        -- it, flag it, and keep the original so the correction is auditable.
        case when unit_price < 0 then null else unit_price end
                                                        as unit_price,
        unit_price                                      as unit_price_raw,
        unit_price < 0                                  as had_negative_price,

        cost_price,
        case
            when unit_price > 0 then round((unit_price - cost_price) / unit_price, 4)
        end                                             as gross_margin_pct,

        supplier,
        extracted_at,
        source_file

    from staged

)

select * from cleaned
