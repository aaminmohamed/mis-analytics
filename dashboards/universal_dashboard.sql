DECLARE global_start_date DATE DEFAULT DATE('2026-05-04');


CREATE OR REPLACE TABLE `tlb-data-dev.KArafa.universal` AS
WITH
    roster AS (
        WITH
            -- these start and end date (OR NULL) define the duration when agent should be handling 'Universal'.
            -- bring agents data in these sites and get the earliest start date.
            step_1 AS (
                SELECT
                    TRIM(t.Population) AS site_name,
                    TRIM(LOWER(t.Business_Email)) AS agent_email,
                    t.Department AS department,
                    t.Transaction_Date AS transaction_date,
                    t.Type AS type,
                    MIN(
                        CASE
                            WHEN t.Type = 'Update'
                            AND t.Department = 'Universal' THEN t.Transaction_Date
                            WHEN t.Type = 'New Batch'
                            AND t.Department = 'Universal' THEN t.Training_Date
                            ELSE NULL
                        END
                    ) OVER (
                        PARTITION BY
                            LOWER(TRIM(t.Business_Email))
                    ) AS start_date
                FROM
                    `tlb-data-dev.ssc_analytics.Talabat_HC_Transactions` AS t
                WHERE
                    TRIM(LOWER(t.Population)) IN ('brightskies', 'mindbridge', 'mindbridge eg')
            ),
            step_2 AS (
                -- here we get the end if it exists and also make sure it's after start date.
                SELECT
                    site_name,
                    agent_email,
                    start_date,
                    MIN(
                        IF(
                            transaction_date >= start_date
                            AND (
                                (
                                    type = 'Update'
                                    AND department != 'Universal'
                                )
                                OR (type = 'Deactivation')
                            ),
                            transaction_date,
                            NULL
                        )
                    ) OVER (
                        PARTITION BY
                            agent_email
                    ) AS end_date
                FROM
                    step_1
                WHERE
                    start_date IS NOT NULL
                QUALIFY
                    ROW_NUMBER() OVER (
                        PARTITION BY
                            agent_email
                    ) = 1
            )
        SELECT
            t.site_name,
            t.agent_email,
            h.Title AS title,
            h.Department AS department,
            h.Country_Q AS country_q,
            h.Batch AS batch,
            h.Reporting_To AS reporting_to,
            CASE
                WHEN REGEXP_CONTAINS(h.Country_Q, r'RS') THEN 'RS'
                WHEN REGEXP_CONTAINS(h.Country_Q, r'PC') THEN 'PS'
                ELSE 'Universal'
            END AS agent_background,
            t.start_date,
            t.end_date,
            h.Status AS status
        FROM
            step_2 AS t
            LEFT JOIN `tlb-data-dev.ssc_analytics.Talabat_HC` AS h ON t.agent_email = TRIM(LOWER(h.Business_Email))
        UNION ALL
        SELECT
            site_name,
            email,
            title,
            'Universal',
            'Universal',
            CAST(batch AS STRING),
            reporting_to,
            'Universal',
            start_date,
            NULL,
            status
        FROM
            `tlb-data-dev.KArafa.universal_agents`
        WHERE
            TRIM(LOWER(site_name)) NOT IN ('brightskies', 'mindbridge', 'mindbridge eg')
    ),
    ids AS (
        SELECT
            u.email,
            id.agent_id,
            r.site_name AS site,
            r.batch,
            r.title,
            r.reporting_to,
            r.agent_background,
            r.start_date AS universal_start_date,
            r.end_date AS universal_end_date,
            r.status
        FROM
            `fulfillment-dwh-production.curated_data_shared.agents` u
            CROSS JOIN UNNEST (u.agent_system_ids) AS id
            INNER JOIN roster AS r ON LOWER(u.email) = r.agent_email
    ),
    orders AS (
        SELECT
            CAST(o.order_id AS STRING) AS order_id,
            o.is_successful,
            o.is_tgo,
            v.vendor_name
        FROM
            `tlb-data-prod.data_platform.fct_order_info` AS o
            LEFT JOIN `tlb-data-prod.data_platform.dim_vendor_info` AS v ON o.vendor_id = v.vendor_id
        WHERE
            order_date BETWEEN global_start_date AND CURRENT_DATE()  - 1
    ),
    chats AS (
        SELECT
            c.chat_id,
            c.order_id,
            c.language,
            c.queue_name,
            RIGHT(c.global_entity_id, 2) AS global_entity_id,
            c.created_date,
            c.hc_identifier,
            c.stakeholder,
            c.agent_id,
            c.handling_time_secs,
            c.contact_reason_l3,
            c.local_contact_reason,
            c.creation_timestamp,
            c.picked_timestamp,
            c.assignement_timestamp,
            c.first_reply_timestamp,
            (
                SELECT
                    MAX(created_at_utc)
                FROM
                    UNNEST (c.message_history)
                WHERE
                    LOWER(sender) = 'agent'
            ) AS last_reply_timestamp,
            c.closed_timestamp,
            c.queue_time_secs,
            c.first_reply_time_secs,
            c.wrap_up_time_secs,
            CASE
                WHEN c.closed_timestamp IS NULL THEN (c.handling_time_secs + c.wrap_up_time_secs)
                ELSE TIMESTAMP_DIFF(
                    c.closed_timestamp,
                    c.assignement_timestamp,
                    SECOND
                )
            END AS handling_time,
            c.missed_chat_ind,
            c.pickup_time_secs,
            c.is_customer_closed,
            o.is_successful,
            o.is_tgo,
            o.vendor_name,
            ids.email,
            ids.site,
            ids.batch,
            ids.title,
            ids.reporting_to,
            ids.universal_start_date,
            ids.universal_end_date,
            ids.status,
            ids.agent_background,
            -- we check if the date of chat is within agent duration in universal or not.
            CASE
                WHEN ids.universal_start_date <= c.created_date
                AND COALESCE(ids.universal_end_date, c.created_date) >= c.created_date THEN 'Universal'
                ELSE ids.agent_background
            END AS origin
        FROM
            `fulfillment-dwh-production.curated_data_shared.herocare_chats` AS c
            INNER JOIN ids ON c.agent_id = ids.agent_id
            LEFT JOIN orders AS o ON c.order_id = o.order_id
        WHERE
            c.created_date BETWEEN global_start_date AND CURRENT_DATE()  - 1
            AND stakeholder IN ('Rider', 'Vendor')
    ),
    sat AS (
        SELECT
            chat_id,
            IF(csat > 3, 1, 0) AS sat,
            IF(csat IS NOT NULL, 1, 0) AS survey,
            csat AS csat_score,
            qcomment AS comment
        FROM
            `fulfillment-dwh-production.curated_data_shared.all_csat_responses`
        WHERE
            created_date BETWEEN global_start_date AND CURRENT_DATE()  - 1
    ),
    fcr AS (
        SELECT
            contact_id,
            fcr_ind,
            fcr_eligibility_ind
        FROM
            `tlb-data-dev.KArafa.cr_all_in_1`
        WHERE
            first_channel = 'Chat'
    ),
    -- not working at the moment.
    qa AS (
        SELECT
            qa.answer_label,
            e.agent_email,
            LOWER(REPLACE(e.reference, '-', '')) AS clean_ref,
            e.is_passed
        FROM
            `fulfillment-dwh-production.curated_data_shared.playvox_evaluations` e
            LEFT JOIN UNNEST (e.custom_fields) AS cf
            LEFT JOIN UNNEST (e.sections) AS s
            LEFT JOIN UNNEST (s.q_and_a) AS qa
            INNER JOIN UNNEST (e.updates) AS u
            INNER JOIN roster AS r ON LOWER(e.agent_email) = r.agent_email
        WHERE
            e.created_date BETWEEN global_start_date AND CURRENT_DATE()  - 1
            AND e.created_date >= r.start_date
            AND LOWER(u.scorecard_name) IN (
                'universal_scorecard_2026',
                'universal_scorecard_2026 - bpo qa'
            )
            AND u.monitor_email IN (
                'mohamed.amer@talabat.com',
                'mona.ahmed@talabat.com',
                'shereen.mohamed.11_bseg.ext@talabat.com',
                'abdelkareem.mohamed.ps10_bseg.ext@talabat.com'
            )
        QUALIFY
            ROW_NUMBER() OVER (
                PARTITION BY
                    e.evaluation_id
                ORDER BY
                    e.created_at
            ) = 1
    ),
    tweetycsat AS (
        SELECT
            chat_id,
            q8
        FROM
            `fulfillment-dwh-production.curated_data_shared.tweety_csat_responses`
        WHERE
            stakeholder IN ('Rider', 'Vendor')
            AND chat_id IS NOT NULL
            AND created_date BETWEEN global_start_date AND CURRENT_DATE()  - 1
    )
SELECT
    chats.chat_id,
    chats.global_entity_id AS country,
    chats.created_date,
    chats.stakeholder,
    chats.agent_id,
    chats.queue_name,
    chats.handling_time_secs,
    chats.contact_reason_l3,
    chats.local_contact_reason AS contact_reason_l4,
    chats.creation_timestamp,
    chats.picked_timestamp,
    chats.assignement_timestamp,
    chats.first_reply_timestamp,
    chats.last_reply_timestamp,
    chats.closed_timestamp,
    chats.queue_time_secs,
    chats.first_reply_time_secs,
    chats.wrap_up_time_secs,
    chats.pickup_time_secs,
    chats.handling_time,
    chats.missed_chat_ind,
    chats.is_customer_closed,
    chats.email,
    chats.site,
    chats.batch,
    chats.origin,
    chats.agent_background,
    chats.title,
    chats.reporting_to,
    chats.universal_start_date,
    chats.universal_end_date,
    chats.order_id,
    chats.language,
    chats.is_successful,
    chats.is_tgo,
    chats.vendor_name,
    CASE
        WHEN tweetycsat.q8 IN ('نعم', 'بەڵێ') THEN 'Yes'
        WHEN tweetycsat.q8 IN ('لا', 'نەخێر') THEN 'No'
        ELSE tweetycsat.q8
    END AS Issue_Resolved,
    sat.sat,
    sat.survey,
    sat.csat_score,
    sat.comment,
    qa.answer_label,
    qa.clean_ref AS referencexx,
    qa.is_passed,
    fcr.fcr_ind,
    fcr.fcr_eligibility_ind
FROM
    chats
    LEFT JOIN sat ON sat.chat_id = chats.hc_identifier
    LEFT JOIN qa ON qa.clean_ref = LOWER(REPLACE(chats.chat_id, '-', ''))
    LEFT JOIN fcr ON fcr.contact_id = chats.chat_id
    LEFT JOIN tweetycsat ON tweetycsat.chat_id = chats.hc_identifier
