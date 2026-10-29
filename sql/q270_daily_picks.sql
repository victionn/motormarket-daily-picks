/* Daily MotorMarket picks – EVERY active bidder (bid in the last 90 days) gets their top 9 live cars, ranked.
   The daily script emails the best 3 the buyer hasn't been shown in their last 3 emails (no repeats).
   Score per buyer x live car (0–1):
     40% price fit   – 1 at the buyer's average reserve, 0 at ±50%
     30% car type    – √(share of their bids on this type). Types: Luxury (BMW, Mercedes, Audi, Lexus,
                       Land Rover, Porsche, Volvo …), Commercial (utes, vans, trucks – incl. Sprinter/Vito),
                       Everyday (everything else)
     20% make        – √(share of their bids on this make): 16% → 0.4, 56% → 0.75, 100% → 1
     10% popularity  – distinct bidders + watchers on the car, relative to the most popular live car
   Variety: soft, not a hard rule. Each extra car of the same make loses 0.15 points, so a second
   Toyota only makes the 3 if it clearly beats the best car of every other make.
   Excludes the buyer's own dealership stock and cars they've already bid on.
   All values are display-ready (HubSpot can't run logic on contact data in emails):
     mp_rec_N_feature_1..3 = "✓ Hybrid", "✓ Panoramic roof", ... (empty when the car has fewer)
     mp_rec_N_odometer = "79,360 KM" or "Not listed"
     mp_rec_N_closes = "Closes Fri 30 Oct, 12pm" (Sydney time)
   Output columns match the HubSpot contact properties; match on Email.
   The last 5 columns are for review only – don't import them. */
WITH user_bids AS (
    /* One row per user per car they have bid on */
    SELECT abh.bidder_id, ab.auction_vehicle_id,
           COUNT(*) AS bid_count, MAX(abh.created_at) AS last_bid_at
    FROM auction_bid_histories abh
    JOIN auction_bids ab ON ab.id = abh.bid_id
    WHERE abh.deleted_at IS NULL
    GROUP BY abh.bidder_id, ab.auction_vehicle_id
),
vehicle_info AS (
    /* vehicles has duplicate rows per id; normalise make/model; classify the car type */
    SELECT v.*,
           CASE
             WHEN (v.make IN ('RAM','ISUZU','FUSO','HINO','IVECO','LDV') AND v.model NOT REGEXP 'MU-X|MUX|D90|DEUTER|MIFA')
               OR v.model REGEXP '^(HILUX|RANGER|NAVARA|TRITON|D-MAX|DMAX|BT-50|BT50|AMAROK|COLORADO$|HIACE|TRANSIT|SPRINTER|VITO|TRANSPORTER|CRAFTER|CADDY|TRAFIC|MASTER|KANGOO|CANTER|EXPRESS|PROACE|T60|T90|G10|DELIVER|CANNON|TUNLAND|ILOAD|STAREX|SCUDO|DUCATO|DAILY|SILVERADO|SIERRA|CQ SIERRA|F-150|F150|F SERIES|GLADIATOR|EXPERT|BOXER|PARTNER|ALASKAN|X-CLASS|RODEO|UTE|N SERIES|NH SERIES|HD)'
               THEN 'Commercial'
             WHEN v.make IN ('BMW','MERCEDES-BENZ','MERCEDES-AMG','AUDI','LEXUS','PORSCHE','LAND ROVER','RANGE ROVER',
                             'JAGUAR','VOLVO','GENESIS','MASERATI','BENTLEY','ROLLS-ROYCE','ASTON MARTIN','FERRARI',
                             'LAMBORGHINI','MCLAREN','ALFA ROMEO','TESLA','INFINITI','CADILLAC','LOTUS','POLESTAR','LINCOLN')
               THEN 'Luxury'
             ELSE 'Everyday'
           END AS vtype
    FROM (
    SELECT id, MAX(UPPER(TRIM(make))) AS make, MAX(UPPER(TRIM(model))) AS model,
           MAX(UPPER(TRIM(variant))) AS variant,
           MAX(year) AS year, MAX(odometer) AS odometer, MAX(vin) AS vin, MAX(nvic) AS nvic,
           MAX(UPPER(JSON_UNQUOTE(JSON_EXTRACT(specification, '$.fuel'))))  AS spec_fuel,
           MAX(UPPER(JSON_UNQUOTE(JSON_EXTRACT(specification, '$.drive')))) AS spec_drive,
           MAX(CAST(JSON_UNQUOTE(JSON_EXTRACT(specification, '$.seats')) AS UNSIGNED)) AS spec_seats
    FROM vehicles GROUP BY id
    ) v
),
recent_bids AS (
    /* Taste is based on the last 12 months only */
    SELECT * FROM user_bids WHERE last_bid_at >= UTC_TIMESTAMP() - INTERVAL 365 DAY
),
bid_cars AS (
    SELECT DISTINCT rb.bidder_id, rb.auction_vehicle_id, vi.make, vi.model, vi.vtype
    FROM recent_bids rb
    JOIN auction_vehicles av  ON av.id = rb.auction_vehicle_id
    JOIN vehicle_contracts vc ON vc.id = av.contract_id
    JOIN vehicle_info vi      ON vi.id = vc.vehicle_id
),
bidder_make AS (
    /* Share of the buyer's bidding per make; affinity = √share so a 16% favourite doesn't dominate */
    SELECT bidder_id, make, cars, share AS make_share, SQRT(share) AS make_rel
    FROM (
        SELECT bidder_id, make, COUNT(*) AS cars,
               COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY bidder_id) AS share
        FROM bid_cars GROUP BY bidder_id, make
    ) x
),
bidder_model AS (
    SELECT bidder_id, make, model, SQRT(share) AS model_rel
    FROM (
        SELECT bidder_id, make, model, COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY bidder_id) AS share
        FROM bid_cars GROUP BY bidder_id, make, model
    ) x
),
bidder_type AS (
    /* Share of the buyer's bidding per car type (Luxury / Commercial / Everyday) */
    SELECT bidder_id, vtype, SQRT(COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY bidder_id)) AS type_rel
    FROM bid_cars GROUP BY bidder_id, vtype
),
favourite_type AS (
    /* Main car type per buyer, for the review column */
    SELECT bidder_id, vtype, type_rel * type_rel AS type_share FROM (
        SELECT bt.*, ROW_NUMBER() OVER (PARTITION BY bidder_id ORDER BY type_rel DESC, vtype) AS rn
        FROM bidder_type bt
    ) r WHERE rn = 1
),
favourite_make AS (
    /* Most-bid make per buyer, for the review column */
    SELECT bidder_id, make, make_share FROM (
        SELECT bm.*, ROW_NUMBER() OVER (PARTITION BY bidder_id ORDER BY cars DESC, make) AS rn
        FROM bidder_make bm
    ) r WHERE rn = 1
),
bidder_reserve AS (
    SELECT rb.bidder_id, AVG(aa.amount) AS avg_reserve
    FROM recent_bids rb
    JOIN auction_vehicles av    ON av.id = rb.auction_vehicle_id
    JOIN acquisition_amounts aa ON aa.contract_id = av.contract_id AND aa.amount_type = 'acquisition'
    GROUP BY rb.bidder_id
),
active_bidders AS (
    /* Everyone who bid in the last 90 days. Only deleted accounts and MotorPlatform staff are left out. */
    SELECT u.id AS user_id, LOWER(TRIM(u.email)) AS email, u.dealership_id,
           MAX(ub.last_bid_at) AS last_bid_at,
           COUNT(DISTINCT CASE WHEN ub.last_bid_at >= UTC_TIMESTAMP() - INTERVAL 30 DAY
                               THEN ub.auction_vehicle_id END) AS cars_bid_30d
    FROM user_bids ub
    JOIN users u ON u.id = ub.bidder_id
    WHERE u.deleted_at IS NULL
      AND u.email IS NOT NULL AND u.email <> ''
      AND u.email NOT LIKE '%@motorplatform.com%'
    GROUP BY u.id, u.email, u.dealership_id
    HAVING MAX(ub.last_bid_at) >= UTC_TIMESTAMP() - INTERVAL 90 DAY
),
live_vehicles AS (
    /* Everything live on MotorMarket that is still open after today's 12pm close; ghost listings < 60 min excluded */
    SELECT av.id AS auction_vehicle_id, av.contract_id, vc.vehicle_id, ag.seller_id, ag.ends_at,
           UPPER(TRIM(ag.state)) AS state,
           vi.make, vi.model, vi.vtype, vi.year, vi.odometer, aa.amount AS reserve,
           vi.variant, vi.vin, vi.spec_fuel, vi.spec_drive, vi.spec_seats, rb.fuel_type AS rb_fuel,
           CASE WHEN vi.odometer REGEXP '^[0-9]+$' THEN CAST(vi.odometer AS UNSIGNED) END AS km
    FROM auction_groups ag
    JOIN auction_vehicles av  ON av.auction_group_id = ag.id AND av.deleted_at IS NULL
    JOIN vehicle_contracts vc ON vc.id = av.contract_id
    JOIN vehicle_info vi      ON vi.id = vc.vehicle_id
    LEFT JOIN redbook_nvic_data rb ON rb.nvic = vi.nvic
    /* one reserve per car (a few cars have two reserve rows, which would duplicate the car) */
    LEFT JOIN (SELECT contract_id, MAX(amount) AS amount FROM acquisition_amounts
               WHERE amount_type = 'acquisition' GROUP BY contract_id) aa ON aa.contract_id = av.contract_id
    WHERE ag.deleted_at IS NULL AND ag.status = 'publish'
      /* still open after today's 12pm close (the script runs before noon, the email goes at 12:05) */
      AND ag.ends_at > GREATEST(UTC_TIMESTAMP(), CONVERT_TZ(CONCAT(DATE(CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', 'Australia/Sydney')), ' 12:00:00'), 'Australia/Sydney', '+00:00'))
      AND TIMESTAMPDIFF(MINUTE, ag.starts_at, ag.ends_at) >= 60
),
live_photo AS (
    /* One listing photo per live car, the same one MotorMarket shows first: photos from both the
       'masthead' and 'additional' categories in gallery order, skipping unlabelled uploads (can be
       invoices), VIN, build-plate and odometer shots when a real car photo exists. Public S3 thumbnail URL. */
    SELECT vehicle_id, image_path FROM (
        SELECT vim.vehicle_id, vim.image_path,
               ROW_NUMBER() OVER (PARTITION BY vim.vehicle_id
                                  ORDER BY (vim.label LIKE 'additional%' OR vim.label IN ('photo-multiple', 'vin', 'build plate', 'odometer')),
                                           vim.`order`, vim.created_at) AS rn
        FROM vehicle_images vim
        WHERE vim.category IN ('masthead', 'additional')
          AND vim.vehicle_id IN (SELECT vehicle_id FROM live_vehicles)
    ) x WHERE rn = 1
),
sp_powertrain AS (
    /* Selling points (1/6). Rego fuel type first ("…/ELECTRIC" = hybrid), then Redbook, then badge */
    SELECT contract_id,
           CASE
             WHEN CONCAT_WS(' ', model, variant) REGEXP 'PHEV|PLUG-IN|PLUG IN|\\bDM-I\\b'          THEN 'Plug-in hybrid'
             WHEN spec_fuel = 'ELECTRIC' OR rb_fuel = 'Electric' OR make = 'TESLA'
               OR (spec_fuel IS NULL AND CONCAT_WS(' ', model, variant) REGEXP '\\bEV\\b|E-TRON|IONIQ 5|IONIQ 6') THEN 'Electric (EV)'
             WHEN spec_fuel LIKE '%/ELECTRIC'
               OR CONCAT_WS(' ', model, variant) REGEXP 'HYBRID|\\bHEV\\b|E:HEV'                    THEN 'Hybrid'
           END AS point
    FROM live_vehicles
),
sp_vin_options AS (
    /* Selling points (2/6). VIN-specific factory options actually fitted; top 2 by price, no paint */
    SELECT contract_id, CONCAT('Factory options: ', GROUP_CONCAT(name ORDER BY price DESC SEPARATOR ', ')) AS point
    FROM (
        SELECT lv.contract_id, o.name, o.price,
               ROW_NUMBER() OVER (PARTITION BY lv.contract_id ORDER BY o.price DESC, o.name) AS rn
        FROM live_vehicles lv
        JOIN redbook_vin_data rv ON rv.vin = lv.vin AND rv.options IS NOT NULL,
        JSON_TABLE(rv.options, '$[*]' COLUMNS (name VARCHAR(120) PATH '$.name',
                                               price DECIMAL(10,2) PATH '$.new_price')) o
        WHERE o.name IS NOT NULL AND o.name NOT REGEXP '(?i)paint'
    ) x
    WHERE rn <= 2
    GROUP BY contract_id
),
sp_service AS (
    /* Selling points (3/6). Service history on file */
    SELECT contract_id, CONCAT('Service history (', MAX(total_records), ' records)') AS point
    FROM service_history_requests
    WHERE is_available = 1 AND total_records > 0
      AND contract_id IN (SELECT contract_id FROM live_vehicles)
    GROUP BY contract_id
),
sp_features AS (
    /* Selling points (4/6). Equipment of the exact variant (Redbook standard list) + seats/drive
       from the rego spec. One per group: panoramic roof beats sunroof. */
    SELECT contract_id, label, prio FROM (
        SELECT contract_id, label, prio,
               ROW_NUMBER() OVER (PARTITION BY contract_id,
                                  CASE WHEN label IN ('Panoramic roof', 'Sunroof') THEN 'roof' ELSE label END
                                  ORDER BY prio) AS rn
        FROM (
            SELECT DISTINCT lv.contract_id,
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
            FROM live_vehicles lv
            JOIN vehicle_options vo ON vo.vehicle_id = lv.vehicle_id,
            JSON_TABLE(vo.options, '$[*]' COLUMNS (name  VARCHAR(200) PATH '$.OptionName',
                                                   otype VARCHAR(20)  PATH '$.OptionType')) o
            WHERE o.otype IN ('A', 'Standard') AND o.name IS NOT NULL
            UNION
            SELECT contract_id, CONCAT(spec_seats, ' seats'), 7 FROM live_vehicles WHERE spec_seats >= 7
            UNION
            SELECT contract_id, 'AWD', 9 FROM live_vehicles WHERE spec_drive REGEXP 'ALL WHEEL|4X4|FOUR WHEEL'
        ) f
        WHERE label IS NOT NULL
    ) r
    WHERE rn = 1
),
sp_all AS (
    /* Selling points (5/6). All candidates with priority: powertrain, low km, factory options,
       service history, features, near new */
    SELECT contract_id, 1 AS prio, point FROM sp_powertrain WHERE point IS NOT NULL
    UNION ALL
    SELECT contract_id, 2,
           CASE WHEN km < 20000 OR km / GREATEST(1, YEAR(UTC_DATE()) - year) < 5000
                THEN CONCAT('Only ', FORMAT(km, 0), ' km')
                ELSE CONCAT('Low km for age (', FORMAT(ROUND(km / GREATEST(1, YEAR(UTC_DATE()) - year), -3), 0), ' km/yr)') END
    FROM live_vehicles
    WHERE km > 0 AND (km < 20000 OR km / GREATEST(1, YEAR(UTC_DATE()) - year) < 10000)
    UNION ALL
    SELECT contract_id, 3, point FROM sp_vin_options
    UNION ALL
    SELECT contract_id, 4, point FROM sp_service
    UNION ALL
    SELECT contract_id, 5 + prio / 100, label FROM sp_features
    UNION ALL
    SELECT contract_id, 6, CONCAT('Near new (', year, ')') FROM live_vehicles WHERE year >= YEAR(UTC_DATE()) - 1
),
selling_points AS (
    /* Selling points (6/6). Top 3 per car, each as its own "✓ ..." line */
    SELECT contract_id,
           MAX(CASE WHEN rn = 1 THEN CONCAT('✓ ', point) END) AS f1,
           MAX(CASE WHEN rn = 2 THEN CONCAT('✓ ', point) END) AS f2,
           MAX(CASE WHEN rn = 3 THEN CONCAT('✓ ', point) END) AS f3
    FROM (
        SELECT contract_id, point, ROW_NUMBER() OVER (PARTITION BY contract_id ORDER BY prio) AS rn
        FROM sp_all
    ) x
    WHERE rn <= 3
    GROUP BY contract_id
),
live_pop AS (
    /* Popularity of each live car: distinct bidders + watchers */
    SELECT lv.auction_vehicle_id, COALESCE(b.bidders, 0) + COALESCE(w.watchers, 0) AS pop
    FROM live_vehicles lv
    LEFT JOIN (SELECT auction_vehicle_id, COUNT(DISTINCT bidder_id) AS bidders
               FROM user_bids GROUP BY auction_vehicle_id) b
           ON b.auction_vehicle_id = lv.auction_vehicle_id
    LEFT JOIN (SELECT auction_vehicle_id, COUNT(DISTINCT buyer_id) AS watchers
               FROM auction_watchlists
               WHERE auction_vehicle_id IN (SELECT auction_vehicle_id FROM live_vehicles)
               GROUP BY auction_vehicle_id) w
           ON w.auction_vehicle_id = lv.auction_vehicle_id
),
scored AS (
    /* Every live car for every active buyer (minus own stock and cars already bid on) */
    SELECT ab.user_id, lv.contract_id, lv.vehicle_id, lv.year, lv.make, lv.model, lv.odometer, lv.state, lv.ends_at,
           0.40 * CASE WHEN br.avg_reserve > 0 AND lv.reserve IS NOT NULL
                       THEN GREATEST(0, 1 - ABS(lv.reserve - br.avg_reserve) / (0.5 * br.avg_reserve))
                       ELSE 0 END
         + 0.30 * COALESCE(bt.type_rel, 0)
         + 0.20 * COALESCE(bmk.make_rel, 0)
         + 0.10 * lp.pop / NULLIF(MAX(lp.pop) OVER (), 0) AS score
    FROM active_bidders ab
    CROSS JOIN live_vehicles lv
    JOIN live_pop lp            ON lp.auction_vehicle_id = lv.auction_vehicle_id
    LEFT JOIN bidder_type bt    ON bt.bidder_id = ab.user_id AND bt.vtype = lv.vtype
    LEFT JOIN bidder_make bmk   ON bmk.bidder_id = ab.user_id AND bmk.make = lv.make
    LEFT JOIN bidder_reserve br ON br.bidder_id = ab.user_id
    WHERE NOT (lv.seller_id <=> ab.dealership_id)
      AND NOT EXISTS (SELECT 1 FROM user_bids ub
                      WHERE ub.bidder_id = ab.user_id AND ub.auction_vehicle_id = lv.auction_vehicle_id)
),
picks AS (
    /* Top 3 per buyer by score, minus 0.15 for each earlier pick of the same make (soft variety) */
    SELECT r.*,
           CONCAT_WS(' ', r.year, r.make, r.model) AS vehicle_name,
           CONCAT('https://app.motorplatform.com.au/motor-market/buying/', r.contract_id,
                  '/summary?utm_source=hubspot&utm_medium=email&utm_campaign=daily_picks') AS link,
           COALESCE(CASE WHEN lp.image_path IS NOT NULL THEN
                CONCAT('https://motor-platform-prod.s3.ap-southeast-2.amazonaws.com/uploads/',
                       SUBSTRING_INDEX(lp.image_path, '/', 1), '/thumbnails/',
                       SUBSTRING_INDEX(lp.image_path, '/', -1)) END,
                'https://42460985.fs1.hubspotusercontent-ap1.net/hub/42460985/hubfs/MotorPlatform_Banner_MP_centered.png') AS image_url,
           CASE WHEN r.odometer REGEXP '^[0-9]+$'
                THEN CONCAT(FORMAT(CAST(r.odometer AS UNSIGNED), 0), ' KM') ELSE 'Not listed' END AS odometer_fmt,
           COALESCE(r.state, 'Not listed') AS state_fmt,
           CONCAT('Closes ', DATE_FORMAT(CONVERT_TZ(r.ends_at, '+00:00', 'Australia/Sydney'), '%a %e %b'), ', ',
                  LOWER(DATE_FORMAT(CONVERT_TZ(r.ends_at, '+00:00', 'Australia/Sydney'),
                        CASE WHEN MINUTE(r.ends_at) = 0 THEN '%l%p' ELSE '%l:%i%p' END))) AS closes_fmt,
           COALESCE(sp.f1, '') AS f1, COALESCE(sp.f2, '') AS f2, COALESCE(sp.f3, '') AS f3
    FROM (
        SELECT m.*, ROW_NUMBER() OVER (PARTITION BY m.user_id
                                       ORDER BY m.score - 0.15 * (m.make_rank - 1) DESC, m.ends_at, m.contract_id) AS rn
        FROM (
            SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.user_id, s.make
                                           ORDER BY s.score DESC, s.contract_id) AS make_rank
            FROM scored s
        ) m
    ) r
    LEFT JOIN live_photo lp     ON lp.vehicle_id = r.vehicle_id
    LEFT JOIN selling_points sp ON sp.contract_id = r.contract_id
    WHERE r.rn <= 9
)
SELECT
    ab.email                                                   AS `Email`,
    MAX(CASE WHEN p.rn = 1 THEN p.vehicle_name END)            AS `mp_rec_1_vehicle`,
    MAX(CASE WHEN p.rn = 1 THEN p.link END)                    AS `mp_rec_1_link`,
    MAX(CASE WHEN p.rn = 1 THEN p.image_url END)               AS `mp_rec_1_image`,
    MAX(CASE WHEN p.rn = 1 THEN p.odometer_fmt END)            AS `mp_rec_1_odometer`,
    MAX(CASE WHEN p.rn = 1 THEN p.state_fmt END)               AS `mp_rec_1_state`,
    MAX(CASE WHEN p.rn = 1 THEN p.closes_fmt END)              AS `mp_rec_1_closes`,
    MAX(CASE WHEN p.rn = 1 THEN p.f1 END)                      AS `mp_rec_1_feature_1`,
    MAX(CASE WHEN p.rn = 1 THEN p.f2 END)                      AS `mp_rec_1_feature_2`,
    MAX(CASE WHEN p.rn = 1 THEN p.f3 END)                      AS `mp_rec_1_feature_3`,
    MAX(CASE WHEN p.rn = 2 THEN p.vehicle_name END)            AS `mp_rec_2_vehicle`,
    MAX(CASE WHEN p.rn = 2 THEN p.link END)                    AS `mp_rec_2_link`,
    MAX(CASE WHEN p.rn = 2 THEN p.image_url END)               AS `mp_rec_2_image`,
    MAX(CASE WHEN p.rn = 2 THEN p.odometer_fmt END)            AS `mp_rec_2_odometer`,
    MAX(CASE WHEN p.rn = 2 THEN p.state_fmt END)               AS `mp_rec_2_state`,
    MAX(CASE WHEN p.rn = 2 THEN p.closes_fmt END)              AS `mp_rec_2_closes`,
    MAX(CASE WHEN p.rn = 2 THEN p.f1 END)                      AS `mp_rec_2_feature_1`,
    MAX(CASE WHEN p.rn = 2 THEN p.f2 END)                      AS `mp_rec_2_feature_2`,
    MAX(CASE WHEN p.rn = 2 THEN p.f3 END)                      AS `mp_rec_2_feature_3`,
    MAX(CASE WHEN p.rn = 3 THEN p.vehicle_name END)            AS `mp_rec_3_vehicle`,
    MAX(CASE WHEN p.rn = 3 THEN p.link END)                    AS `mp_rec_3_link`,
    MAX(CASE WHEN p.rn = 3 THEN p.image_url END)               AS `mp_rec_3_image`,
    MAX(CASE WHEN p.rn = 3 THEN p.odometer_fmt END)            AS `mp_rec_3_odometer`,
    MAX(CASE WHEN p.rn = 3 THEN p.state_fmt END)               AS `mp_rec_3_state`,
    MAX(CASE WHEN p.rn = 3 THEN p.closes_fmt END)              AS `mp_rec_3_closes`,
    MAX(CASE WHEN p.rn = 3 THEN p.f1 END)                      AS `mp_rec_3_feature_1`,
    MAX(CASE WHEN p.rn = 3 THEN p.f2 END)                      AS `mp_rec_3_feature_2`,
    MAX(CASE WHEN p.rn = 3 THEN p.f3 END)                      AS `mp_rec_3_feature_3`,
    MAX(CASE WHEN p.rn = 4 THEN p.vehicle_name END)            AS `mp_rec_4_vehicle`,
    MAX(CASE WHEN p.rn = 4 THEN p.link END)                    AS `mp_rec_4_link`,
    MAX(CASE WHEN p.rn = 4 THEN p.image_url END)               AS `mp_rec_4_image`,
    MAX(CASE WHEN p.rn = 4 THEN p.odometer_fmt END)            AS `mp_rec_4_odometer`,
    MAX(CASE WHEN p.rn = 4 THEN p.state_fmt END)               AS `mp_rec_4_state`,
    MAX(CASE WHEN p.rn = 4 THEN p.closes_fmt END)              AS `mp_rec_4_closes`,
    MAX(CASE WHEN p.rn = 4 THEN p.f1 END)                      AS `mp_rec_4_feature_1`,
    MAX(CASE WHEN p.rn = 4 THEN p.f2 END)                      AS `mp_rec_4_feature_2`,
    MAX(CASE WHEN p.rn = 4 THEN p.f3 END)                      AS `mp_rec_4_feature_3`,
    MAX(CASE WHEN p.rn = 5 THEN p.vehicle_name END)            AS `mp_rec_5_vehicle`,
    MAX(CASE WHEN p.rn = 5 THEN p.link END)                    AS `mp_rec_5_link`,
    MAX(CASE WHEN p.rn = 5 THEN p.image_url END)               AS `mp_rec_5_image`,
    MAX(CASE WHEN p.rn = 5 THEN p.odometer_fmt END)            AS `mp_rec_5_odometer`,
    MAX(CASE WHEN p.rn = 5 THEN p.state_fmt END)               AS `mp_rec_5_state`,
    MAX(CASE WHEN p.rn = 5 THEN p.closes_fmt END)              AS `mp_rec_5_closes`,
    MAX(CASE WHEN p.rn = 5 THEN p.f1 END)                      AS `mp_rec_5_feature_1`,
    MAX(CASE WHEN p.rn = 5 THEN p.f2 END)                      AS `mp_rec_5_feature_2`,
    MAX(CASE WHEN p.rn = 5 THEN p.f3 END)                      AS `mp_rec_5_feature_3`,
    MAX(CASE WHEN p.rn = 6 THEN p.vehicle_name END)            AS `mp_rec_6_vehicle`,
    MAX(CASE WHEN p.rn = 6 THEN p.link END)                    AS `mp_rec_6_link`,
    MAX(CASE WHEN p.rn = 6 THEN p.image_url END)               AS `mp_rec_6_image`,
    MAX(CASE WHEN p.rn = 6 THEN p.odometer_fmt END)            AS `mp_rec_6_odometer`,
    MAX(CASE WHEN p.rn = 6 THEN p.state_fmt END)               AS `mp_rec_6_state`,
    MAX(CASE WHEN p.rn = 6 THEN p.closes_fmt END)              AS `mp_rec_6_closes`,
    MAX(CASE WHEN p.rn = 6 THEN p.f1 END)                      AS `mp_rec_6_feature_1`,
    MAX(CASE WHEN p.rn = 6 THEN p.f2 END)                      AS `mp_rec_6_feature_2`,
    MAX(CASE WHEN p.rn = 6 THEN p.f3 END)                      AS `mp_rec_6_feature_3`,
    MAX(CASE WHEN p.rn = 7 THEN p.vehicle_name END)            AS `mp_rec_7_vehicle`,
    MAX(CASE WHEN p.rn = 7 THEN p.link END)                    AS `mp_rec_7_link`,
    MAX(CASE WHEN p.rn = 7 THEN p.image_url END)               AS `mp_rec_7_image`,
    MAX(CASE WHEN p.rn = 7 THEN p.odometer_fmt END)            AS `mp_rec_7_odometer`,
    MAX(CASE WHEN p.rn = 7 THEN p.state_fmt END)               AS `mp_rec_7_state`,
    MAX(CASE WHEN p.rn = 7 THEN p.closes_fmt END)              AS `mp_rec_7_closes`,
    MAX(CASE WHEN p.rn = 7 THEN p.f1 END)                      AS `mp_rec_7_feature_1`,
    MAX(CASE WHEN p.rn = 7 THEN p.f2 END)                      AS `mp_rec_7_feature_2`,
    MAX(CASE WHEN p.rn = 7 THEN p.f3 END)                      AS `mp_rec_7_feature_3`,
    MAX(CASE WHEN p.rn = 8 THEN p.vehicle_name END)            AS `mp_rec_8_vehicle`,
    MAX(CASE WHEN p.rn = 8 THEN p.link END)                    AS `mp_rec_8_link`,
    MAX(CASE WHEN p.rn = 8 THEN p.image_url END)               AS `mp_rec_8_image`,
    MAX(CASE WHEN p.rn = 8 THEN p.odometer_fmt END)            AS `mp_rec_8_odometer`,
    MAX(CASE WHEN p.rn = 8 THEN p.state_fmt END)               AS `mp_rec_8_state`,
    MAX(CASE WHEN p.rn = 8 THEN p.closes_fmt END)              AS `mp_rec_8_closes`,
    MAX(CASE WHEN p.rn = 8 THEN p.f1 END)                      AS `mp_rec_8_feature_1`,
    MAX(CASE WHEN p.rn = 8 THEN p.f2 END)                      AS `mp_rec_8_feature_2`,
    MAX(CASE WHEN p.rn = 8 THEN p.f3 END)                      AS `mp_rec_8_feature_3`,
    MAX(CASE WHEN p.rn = 9 THEN p.vehicle_name END)            AS `mp_rec_9_vehicle`,
    MAX(CASE WHEN p.rn = 9 THEN p.link END)                    AS `mp_rec_9_link`,
    MAX(CASE WHEN p.rn = 9 THEN p.image_url END)               AS `mp_rec_9_image`,
    MAX(CASE WHEN p.rn = 9 THEN p.odometer_fmt END)            AS `mp_rec_9_odometer`,
    MAX(CASE WHEN p.rn = 9 THEN p.state_fmt END)               AS `mp_rec_9_state`,
    MAX(CASE WHEN p.rn = 9 THEN p.closes_fmt END)              AS `mp_rec_9_closes`,
    MAX(CASE WHEN p.rn = 9 THEN p.f1 END)                      AS `mp_rec_9_feature_1`,
    MAX(CASE WHEN p.rn = 9 THEN p.f2 END)                      AS `mp_rec_9_feature_2`,
    MAX(CASE WHEN p.rn = 9 THEN p.f3 END)                      AS `mp_rec_9_feature_3`,
    DATE_FORMAT(UTC_TIMESTAMP(), '%Y-%m-%dT%H:%i:%sZ')         AS `mp_rec_generated_at`,
    /* Review columns – don't import */
    ROUND(MAX(CASE WHEN p.rn = 1 THEN p.score END), 3)         AS `top_score`,
    ab.cars_bid_30d                                            AS `cars_bid_30d`,
    CONCAT(fm.make, ' (', ROUND(100 * fm.make_share), '%)')    AS `usual_make`,
    CONCAT(ft.vtype, ' (', ROUND(100 * ft.type_share), '%)')   AS `usual_type`,
    ROUND(br.avg_reserve)                                      AS `usual_reserve`
FROM active_bidders ab
JOIN picks p                ON p.user_id = ab.user_id
LEFT JOIN favourite_make fm ON fm.bidder_id = ab.user_id
LEFT JOIN favourite_type ft ON ft.bidder_id = ab.user_id
LEFT JOIN bidder_reserve br ON br.bidder_id = ab.user_id
GROUP BY ab.user_id, ab.email, ab.cars_bid_30d, fm.make, fm.make_share, ft.vtype, ft.type_share, br.avg_reserve
ORDER BY ab.cars_bid_30d DESC
