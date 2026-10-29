/* MotorMarket – vehicles on the NEXT closing day (Sydney date), top 10, with up to 3 selling points each.
   Ranked by distinct bidders + watchers. Same list for every buyer.
   All auctions close at 12pm Sydney; cars closing at today's 12pm are excluded (the email goes at 12:05),
   so this is the next closing day: tomorrow, or Monday over a weekend.
   Selling points, in priority order (top 3 kept):
     1. Electric / Hybrid / Plug-in hybrid
     2. Low km  ("Only 8,900 km" under 20k or under 5k km/yr; "Low km for age" under 10k km/yr)
     3. Factory options fitted (VIN-specific Redbook lookup; top 2 by new price, paint excluded)
     4. Service history on file
     5. Key features of the variant (panoramic roof/sunroof, leather, 360 camera, HUD,
        ventilated seats, 7+ seats, adaptive cruise, AWD)
     6. Near new */
WITH vehicle_info AS (
    SELECT id, MAX(UPPER(TRIM(make))) AS make, MAX(UPPER(TRIM(model))) AS model,
           MAX(UPPER(TRIM(variant))) AS variant,
           MAX(year) AS year, MAX(odometer) AS odometer, MAX(vin) AS vin, MAX(nvic) AS nvic,
           MAX(UPPER(JSON_UNQUOTE(JSON_EXTRACT(specification, '$.fuel'))))  AS spec_fuel,
           MAX(UPPER(JSON_UNQUOTE(JSON_EXTRACT(specification, '$.drive')))) AS spec_drive,
           MAX(CAST(JSON_UNQUOTE(JSON_EXTRACT(specification, '$.seats')) AS UNSIGNED)) AS spec_seats
    FROM vehicles GROUP BY id
),
ending AS (
    SELECT av.id AS auction_vehicle_id, av.contract_id, vc.vehicle_id, ag.ends_at,
           UPPER(TRIM(ag.state)) AS state, vi.year, vi.make, vi.model, vi.variant, vi.odometer, vi.vin,
           vi.spec_fuel, vi.spec_drive, vi.spec_seats, rn.fuel_type AS rb_fuel,
           CASE WHEN vi.odometer REGEXP '^[0-9]+$' THEN CAST(vi.odometer AS UNSIGNED) END AS km
    FROM auction_groups ag
    JOIN auction_vehicles av  ON av.auction_group_id = ag.id AND av.deleted_at IS NULL
    JOIN vehicle_contracts vc ON vc.id = av.contract_id
    JOIN vehicle_info vi      ON vi.id = vc.vehicle_id
    LEFT JOIN redbook_nvic_data rn ON rn.nvic = vi.nvic
    WHERE ag.deleted_at IS NULL AND ag.status = 'publish'
      AND ag.ends_at > GREATEST(UTC_TIMESTAMP(), CONVERT_TZ(CONCAT(DATE(CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', 'Australia/Sydney')), ' 12:00:00'), 'Australia/Sydney', '+00:00'))
      AND TIMESTAMPDIFF(MINUTE, ag.starts_at, ag.ends_at) >= 60   -- skip ghost listings
      /* the next day that has auctions closing (tomorrow when the email goes at 1pm) */
      AND DATE(CONVERT_TZ(ag.ends_at, '+00:00', 'Australia/Sydney')) = (
            SELECT MIN(DATE(CONVERT_TZ(ag2.ends_at, '+00:00', 'Australia/Sydney')))
            FROM auction_groups ag2
            WHERE ag2.deleted_at IS NULL AND ag2.status = 'publish'
              AND ag2.ends_at > GREATEST(UTC_TIMESTAMP(), CONVERT_TZ(CONCAT(DATE(CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', 'Australia/Sydney')), ' 12:00:00'), 'Australia/Sydney', '+00:00'))
              AND TIMESTAMPDIFF(MINUTE, ag2.starts_at, ag2.ends_at) >= 60)
),
bidders AS (
    SELECT ab.auction_vehicle_id, COUNT(DISTINCT abh.bidder_id) AS bidders
    FROM auction_bids ab
    JOIN auction_bid_histories abh ON abh.bid_id = ab.id AND abh.deleted_at IS NULL
    WHERE ab.auction_vehicle_id IN (SELECT auction_vehicle_id FROM ending)
    GROUP BY ab.auction_vehicle_id
),
watchers AS (
    SELECT auction_vehicle_id, COUNT(DISTINCT buyer_id) AS watchers
    FROM auction_watchlists
    WHERE auction_vehicle_id IN (SELECT auction_vehicle_id FROM ending)
    GROUP BY auction_vehicle_id
),
photo AS (
    SELECT vehicle_id, image_path FROM (
        SELECT vim.vehicle_id, vim.image_path,
               ROW_NUMBER() OVER (PARTITION BY vim.vehicle_id
                                  ORDER BY (vim.label LIKE 'additional%' OR vim.label IN ('photo-multiple', 'vin', 'build plate', 'odometer')),
                                           vim.`order`, vim.created_at) AS rn
        FROM vehicle_images vim
        WHERE vim.category IN ('masthead', 'additional')
          AND vim.vehicle_id IN (SELECT vehicle_id FROM ending)
    ) x WHERE rn = 1
),
powertrain AS (
    /* Rego fuel type first ("…/ELECTRIC" = hybrid), then Redbook, then the badge */
    SELECT e.contract_id,
           CASE
             WHEN CONCAT_WS(' ', e.model, e.variant) REGEXP 'PHEV|PLUG-IN|PLUG IN|\\bDM-I\\b'     THEN 'Plug-in hybrid'
             WHEN e.spec_fuel = 'ELECTRIC' OR e.rb_fuel = 'Electric' OR e.make = 'TESLA'
               OR (e.spec_fuel IS NULL AND CONCAT_WS(' ', e.model, e.variant) REGEXP '\\bEV\\b|E-TRON|IONIQ 5|IONIQ 6') THEN 'Electric'
             WHEN e.spec_fuel LIKE '%/ELECTRIC'
               OR CONCAT_WS(' ', e.model, e.variant) REGEXP 'HYBRID|\\bHEV\\b|E:HEV'               THEN 'Hybrid'
             WHEN COALESCE(e.spec_fuel, UPPER(e.rb_fuel)) LIKE '%DIESEL%'                          THEN 'Diesel'
             WHEN COALESCE(e.spec_fuel, UPPER(e.rb_fuel)) REGEXP 'LPG|GAS'                          THEN 'LPG'
             WHEN COALESCE(e.spec_fuel, e.rb_fuel) IS NOT NULL                                      THEN 'Petrol'
             ELSE 'Unknown'
           END AS powertrain
    FROM ending e
),
vin_options AS (
    /* VIN-specific factory options actually fitted; top 2 by new price, paint excluded */
    SELECT contract_id, CONCAT('Factory options: ', GROUP_CONCAT(name ORDER BY price DESC SEPARATOR ', ')) AS point
    FROM (
        SELECT e.contract_id, o.name, o.price,
               ROW_NUMBER() OVER (PARTITION BY e.contract_id ORDER BY o.price DESC, o.name) AS rn
        FROM ending e
        JOIN redbook_vin_data rv ON rv.vin = e.vin AND rv.options IS NOT NULL,
        JSON_TABLE(rv.options, '$[*]' COLUMNS (name VARCHAR(120) PATH '$.name',
                                               price DECIMAL(10,2) PATH '$.new_price')) o
        WHERE o.name IS NOT NULL AND o.name NOT REGEXP '(?i)paint'
    ) x
    WHERE rn <= 2
    GROUP BY contract_id
),
service_hist AS (
    SELECT contract_id, CONCAT('Service history on file (', MAX(total_records), ' records)') AS point
    FROM service_history_requests
    WHERE is_available = 1 AND total_records > 0
      AND contract_id IN (SELECT contract_id FROM ending)
    GROUP BY contract_id
),
features AS (
    /* Equipment of the exact variant (Redbook standard list) + seats/drive from the rego spec.
       Each feature is its own point; panoramic roof beats sunroof. */
    SELECT contract_id, label, prio FROM (
        SELECT contract_id, label, prio,
               ROW_NUMBER() OVER (PARTITION BY contract_id,
                                  CASE WHEN label IN ('Panoramic roof', 'Sunroof') THEN 'roof' ELSE label END
                                  ORDER BY prio) AS rn
        FROM (
            SELECT DISTINCT e.contract_id,
                   CASE
                     WHEN UPPER(o.name) REGEXP 'PANORAMIC'                                    THEN 'Panoramic roof'
                     WHEN UPPER(o.name) REGEXP 'SUNROOF|MOONROOF'                             THEN 'Sunroof'
                     WHEN UPPER(o.name) REGEXP 'LEATHER'
                      AND UPPER(o.name) NOT REGEXP 'STEERING|GEAR|SHIFT|KNOB|WHEEL'           THEN 'Leather'
                     WHEN UPPER(o.name) REGEXP '360'                                          THEN '360° camera'
                     WHEN UPPER(o.name) REGEXP 'HEAD.?UP|\\bHUD\\b'                           THEN 'Head-up display'
                     WHEN UPPER(o.name) REGEXP 'VENTILAT'                                     THEN 'Ventilated seats'
                     WHEN UPPER(o.name) REGEXP 'ADAPTIVE CRUISE'                              THEN 'Adaptive cruise'
                   END AS label,
                   CASE
                     WHEN UPPER(o.name) REGEXP 'PANORAMIC'                                    THEN 1
                     WHEN UPPER(o.name) REGEXP 'SUNROOF|MOONROOF'                             THEN 2
                     WHEN UPPER(o.name) REGEXP 'LEATHER'
                      AND UPPER(o.name) NOT REGEXP 'STEERING|GEAR|SHIFT|KNOB|WHEEL'           THEN 3
                     WHEN UPPER(o.name) REGEXP '360'                                          THEN 4
                     WHEN UPPER(o.name) REGEXP 'HEAD.?UP|\\bHUD\\b'                           THEN 5
                     WHEN UPPER(o.name) REGEXP 'VENTILAT'                                     THEN 6
                     WHEN UPPER(o.name) REGEXP 'ADAPTIVE CRUISE'                              THEN 8
                   END AS prio
            FROM ending e
            JOIN vehicle_options vo ON vo.vehicle_id = e.vehicle_id,
            JSON_TABLE(vo.options, '$[*]' COLUMNS (name  VARCHAR(200) PATH '$.OptionName',
                                                   otype VARCHAR(20)  PATH '$.OptionType')) o
            WHERE o.otype IN ('A', 'Standard') AND o.name IS NOT NULL
            UNION
            SELECT contract_id, CONCAT(spec_seats, ' seats'), 7 FROM ending WHERE spec_seats >= 7
            UNION
            SELECT contract_id, 'AWD', 9 FROM ending WHERE spec_drive REGEXP 'ALL WHEEL|4X4|FOUR WHEEL'
        ) f
        WHERE label IS NOT NULL
    ) r
    WHERE rn = 1
),
points AS (
    SELECT e.contract_id, 1 AS prio,
           CASE pt.powertrain WHEN 'Electric' THEN 'Electric (EV)' ELSE pt.powertrain END AS point
    FROM ending e JOIN powertrain pt ON pt.contract_id = e.contract_id
    WHERE pt.powertrain IN ('Electric', 'Hybrid', 'Plug-in hybrid')
    UNION ALL
    SELECT contract_id, 2,
           CASE WHEN km < 20000 OR km / GREATEST(1, YEAR(UTC_DATE()) - year) < 5000
                THEN CONCAT('Only ', FORMAT(km, 0), ' km')
                ELSE CONCAT('Low km for age (', FORMAT(ROUND(km / GREATEST(1, YEAR(UTC_DATE()) - year), -3), 0), ' km/yr)') END
    FROM ending
    WHERE km > 0 AND (km < 20000 OR km / GREATEST(1, YEAR(UTC_DATE()) - year) < 10000)
    UNION ALL
    SELECT contract_id, 3, point FROM vin_options
    UNION ALL
    SELECT contract_id, 4, point FROM service_hist
    UNION ALL
    SELECT contract_id, 5 + prio / 100, label FROM features
    UNION ALL
    SELECT contract_id, 6, CONCAT('Near new (', year, ')') FROM ending WHERE year >= YEAR(UTC_DATE()) - 1
),
ranked AS (
    SELECT contract_id, point, ROW_NUMBER() OVER (PARTITION BY contract_id ORDER BY prio) AS rn
    FROM points
),
selling_points AS (
    SELECT contract_id,
           MAX(CASE WHEN rn = 1 THEN point END) AS point_1,
           MAX(CASE WHEN rn = 2 THEN point END) AS point_2,
           MAX(CASE WHEN rn = 3 THEN point END) AS point_3
    FROM ranked WHERE rn <= 3
    GROUP BY contract_id
)
SELECT
    ROW_NUMBER() OVER (ORDER BY COALESCE(b.bidders, 0) + COALESCE(w.watchers, 0) DESC,
                                e.contract_id)                          AS `rank`,
    e.contract_id                                                      AS `contract_id`,
    CONCAT_WS(' ', e.year, e.make, e.model)                            AS `vehicle`,
    e.state                                                            AS `state`,
    e.vin                                                              AS `VIN`,
    CASE WHEN e.odometer REGEXP '^[0-9]+$'
         THEN FORMAT(CAST(e.odometer AS UNSIGNED), 0) END              AS `odometer`,
    pt.powertrain                                                      AS `powertrain`,
    sp.point_1                                                         AS `point_1`,
    sp.point_2                                                         AS `point_2`,
    sp.point_3                                                         AS `point_3`,
    COALESCE(b.bidders, 0)                                             AS `bidders`,
    COALESCE(w.watchers, 0)                                            AS `watchers`,
    CONVERT_TZ(e.ends_at, '+00:00', 'Australia/Sydney')                AS `ends_at_sydney`,
    CONCAT('https://app.motorplatform.com.au/motor-market/buying/', e.contract_id,
           '/summary?utm_source=hubspot&utm_medium=email&utm_campaign=daily_picks&utm_content=ending_today') AS `link`,
    CASE WHEN p.image_path IS NOT NULL THEN
         CONCAT('https://motor-platform-prod.s3.ap-southeast-2.amazonaws.com/uploads/',
                SUBSTRING_INDEX(p.image_path, '/', 1), '/thumbnails/',
                SUBSTRING_INDEX(p.image_path, '/', -1)) END            AS `image`
FROM ending e
LEFT JOIN bidders        b  ON b.auction_vehicle_id = e.auction_vehicle_id
LEFT JOIN watchers       w  ON w.auction_vehicle_id = e.auction_vehicle_id
LEFT JOIN photo          p  ON p.vehicle_id = e.vehicle_id
LEFT JOIN powertrain     pt ON pt.contract_id = e.contract_id
LEFT JOIN selling_points sp ON sp.contract_id = e.contract_id
ORDER BY `rank`
LIMIT 10
