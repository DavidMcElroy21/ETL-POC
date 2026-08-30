{{ config(materialized='table') }}

-- Curated store dimension.
--
-- Nothing to clean: the source is defect-free by design. Kept as a model rather
-- than pointing consumers at staging so the marts layer is complete on its own
-- and the star schema has a real store dimension to join to.

select
    store_id,
    store_name,
    city,
    country                                             as country_code,
    region,
    opened_date,
    square_feet,
    extracted_at,
    source_file

from {{ ref('stg_stores') }}
