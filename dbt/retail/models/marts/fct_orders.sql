{{ config(materialized='table') }}

-- Order fact table.
--
-- Orphaned and undated orders are retained rather than dropped, with flags that
-- make them easy to exclude. Deleting rows to make a test pass loses the very
-- signal the pipeline exists to surface; flagging them lets a consumer choose.

with staged as (

    select * from {{ ref('stg_orders') }}

),

deduplicated as (

    -- DQ-09: one order id appears twice.
    select
        *,
        row_number() over (
            partition by order_id
            order by extracted_at desc, source_file desc
        ) as _row_number

    from staged

),

items as (

    select
        order_id,
        count(*)                                        as line_count,
        sum(quantity)                                   as total_units,
        sum(line_total)                                 as order_total

    from {{ ref('stg_order_items') }}
    group by order_id

),

final as (

    select
        o.order_id,
        o.customer_id,
        o.store_id,
        o.order_date,

        -- DQ-08: fold case and strip the trailing space that makes 'shipped '
        -- look identical to 'shipped'. Anything still unrecognised becomes
        -- 'unknown' rather than being guessed at.
        case lower(trim(o.status))
            when 'placed' then 'placed'
            when 'picked' then 'picked'
            when 'shipped' then 'shipped'
            when 'delivered' then 'delivered'
            when 'returned' then 'returned'
            else 'unknown'
        end                                             as status,
        o.status                                        as status_raw,

        o.channel,
        o.currency,

        coalesce(i.line_count, 0)                       as line_count,
        coalesce(i.total_units, 0)                      as total_units,
        coalesce(i.order_total, 0)                      as order_total,

        -- DQ-07: the customer is missing from the dimension.
        c.customer_id is null                           as is_orphaned_customer,
        -- DQ-10: no order date on the source record.
        o.order_date is null                            as is_missing_order_date,

        o.extracted_at,
        o.source_file

    from deduplicated       as o
    left join {{ ref('dim_customers') }} as c on o.customer_id = c.customer_id
    left join items         as i on o.order_id = i.order_id
    where o._row_number = 1

)

select * from final
