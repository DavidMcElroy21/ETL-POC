{{ config(materialized='view') }}

with source as (

    select * from {{ source('airbyte_raw', 'orders') }}

),

renamed as (

    select
        order_id,

        -- DQ-07 seeds five orders whose customer does not exist.
        customer_id,
        store_id,

        -- DQ-10 seeds two orders with no date. The empty CSV field becomes SQL
        -- NULL because the connector stream sets null_values explicitly.
        cast(order_date as date)                        as order_date,

        -- DQ-08 seeds four status values outside the vocabulary, one of them
        -- differing only by a trailing space. Preserved byte for byte, because
        -- trimming here would hide exactly the defect worth surfacing.
        status,
        channel,
        currency,

        cast(_airbyte_extracted_at as timestamp)        as extracted_at,
        _ab_source_file_url                             as source_file,
        cast(_ab_source_file_last_modified as timestamp) as source_file_modified_at

    from source

)

select * from renamed
