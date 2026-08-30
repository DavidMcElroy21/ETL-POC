{{ config(materialized='table') }}

-- Order line item fact table.

with staged as (

    select * from {{ ref('stg_order_items') }}

),

final as (

    select
        i.order_item_id,
        i.order_id,
        i.product_id,

        i.quantity,
        i.unit_price,
        i.discount_pct,
        i.line_total                                    as line_total_reported,
        i.expected_line_total                           as line_total_expected,
        round(i.line_total - i.expected_line_total, 2)  as line_total_variance,

        -- DQ-11: quantity outside the plausible range.
        i.quantity < 1                                  as is_invalid_quantity,
        -- DQ-12: reported total disagrees with the arithmetic.
        abs(i.line_total - i.expected_line_total) > 0.01 as has_total_variance,
        -- DQ-13: the parent order is missing.
        o.order_id is null                              as is_orphaned_order,

        i.extracted_at,
        i.source_file

    from staged as i
    left join {{ ref('fct_orders') }} as o on i.order_id = o.order_id

)

select * from final
