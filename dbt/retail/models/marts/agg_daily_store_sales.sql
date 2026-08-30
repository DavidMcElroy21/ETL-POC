{{ config(materialized='table') }}

-- Daily sales by store: the model an actual consumer would query.
--
-- Deliberately built from the clean subset. Orders with no date, an unknown
-- status or a missing customer are excluded here, and the counts of what was
-- excluded travel with each row so a reader can see the size of what the
-- warnings were pointing at rather than having to trust that it was small.

with orders as (

    select * from {{ ref('fct_orders') }}

),

excluded as (

    select
        order_date,
        store_id,
        count(*) filter (where is_missing_order_date)   as excluded_missing_date,
        count(*) filter (where is_orphaned_customer)    as excluded_orphaned_customer,
        count(*) filter (where status = 'unknown')      as excluded_unknown_status

    from orders
    group by order_date, store_id

),

daily as (

    select
        o.order_date,
        o.store_id,
        s.store_name,
        s.country_code,
        s.region,

        count(*)                                        as order_count,
        sum(o.total_units)                              as units_sold,
        round(sum(o.order_total), 2)                    as gross_sales,
        round(avg(o.order_total), 2)                    as average_order_value,
        count(distinct o.customer_id)                   as distinct_customers

    from orders as o
    inner join {{ ref('dim_stores') }} as s on o.store_id = s.store_id

    where o.order_date is not null
      and o.status <> 'unknown'
      and not o.is_orphaned_customer

    group by o.order_date, o.store_id, s.store_name, s.country_code, s.region

)

select
    d.*,
    coalesce(e.excluded_missing_date, 0)                as excluded_missing_date,
    coalesce(e.excluded_orphaned_customer, 0)           as excluded_orphaned_customer,
    coalesce(e.excluded_unknown_status, 0)              as excluded_unknown_status

from daily as d
left join excluded as e
    on d.order_date = e.order_date
   and d.store_id = e.store_id

order by d.order_date, d.store_id
