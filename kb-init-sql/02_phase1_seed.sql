-- =========================
-- 0) Seed a user
-- =========================
INSERT INTO users (id, email, name) VALUES (1, 'seed@kb.local', 'Seed User') ON CONFLICT (id) DO NOTHING;

-- =========================
-- 1) Nodes (Set A: initial table definitions)
-- =========================
WITH t(table_name) AS (
  VALUES
    ('billing_invoicedetail'),
    ('billing_payment'),
    ('billing_payment_invoices'),
    ('billing_invoice'),
    ('policy_fairdeesaleinvoice'),
    ('policy_fairdeesale'),
    ('utils_fairdeequotation'),
    ('utils_fairdeequotationquery'),
    ('billing_instalmenttype'),
    ('policy_fairdeesale_historical'),
    ('policy_fairdeepolicy'),
    ('masterdata_pricelist')
)
INSERT INTO nodes (table_name, created_by)
SELECT table_name, 1 FROM t
ON CONFLICT (table_name) DO NOTHING;

-- =========================
-- 2) Node Columns (Set A)
-- =========================
WITH c(table_name, column_name, query_role) AS (
  VALUES
  -- billing_invoicedetail
  ('billing_invoicedetail','invoice_id','display_column'),
  ('billing_invoicedetail','detail_type','filter_condition'),
  ('billing_invoicedetail','amount','display_column'),
  
  -- billing_payment
  ('billing_payment','id','display_column'),
  ('billing_payment','paid_at','display_column'),
  ('billing_payment','amount_paid','display_column'),
  ('billing_payment','is_deleted','filter_condition'),
  ('billing_payment','is_reconciled','filter_condition'),
  
  -- billing_payment_invoices
  ('billing_payment_invoices','invoice_id','display_column'),
  ('billing_payment_invoices','payment_id','display_column'),
  
  -- billing_invoice
  ('billing_invoice','id','display_column'),
  ('billing_invoice','is_deleted','filter_condition'),
  ('billing_invoice','payer','filter_condition'),
  ('billing_invoice','payee','filter_condition'),
  ('billing_invoice','amount_payable','display_column'),
  ('billing_invoice','payment_status','display_column'),
  
  -- policy_fairdeesaleinvoice
  ('policy_fairdeesaleinvoice','fairdee_sale_id','display_column'),
  ('policy_fairdeesaleinvoice','invoice_id','display_column'),
  
  -- policy_fairdeesale
  ('policy_fairdeesale','id','display_column'),
  ('policy_fairdeesale','quotation_id','display_column'),
  ('policy_fairdeesale','sold_on','date_filter'),
  ('policy_fairdeesale','policy_status','filter_condition'),
  ('policy_fairdeesale','payment_status','filter_condition'),
  ('policy_fairdeesale','sale_type','filter_condition'),
  ('policy_fairdeesale','created_at','date_filter'),
  ('policy_fairdeesale','voluntary_policy_id','display_column'),
  ('policy_fairdeesale','affiliate_id','display_column'),
  ('policy_fairdeesale','sub_affiliate_id','display_column'),
  
  -- utils_fairdeequotation
  ('utils_fairdeequotation','id','display_column'),
  ('utils_fairdeequotation','quotation_query_id','display_column'),
  ('utils_fairdeequotation','price_list_id','display_column'),
  ('utils_fairdeequotation','vmi_insurer_commission_rate','filter_condition'),
  ('utils_fairdeequotation','cmi_insurer_commission_rate','filter_condition'),
  ('utils_fairdeequotation','commission_rate','filter_condition'),
  ('utils_fairdeequotation','affiliate_discount','display_column'),
  ('utils_fairdeequotation','assistance_deduction_rate','display_column'),
  ('utils_fairdeequotation','cmi_affiliate_discount','display_column'),
  ('utils_fairdeequotation','needs_compulsory_insurance','filter_condition'),
  ('utils_fairdeequotation','is_self_serve','display_column'),
  ('utils_fairdeequotation','policy_start_date','date_filter'),
  ('utils_fairdeequotation','chassis_number','display_column'),
  ('utils_fairdeequotation','vehicle_number','display_column'),
  
  -- utils_fairdeequotationquery
  ('utils_fairdeequotationquery','id','display_column'),
  ('utils_fairdeequotationquery','instalment_type_id','display_column'),
  ('utils_fairdeequotationquery','affiliate_to_customer_discount','display_column'),
  ('utils_fairdeequotationquery','vmi_car_code','display_column'),
  
  -- billing_instalmenttype
  ('billing_instalmenttype','id','display_column'),
  ('billing_instalmenttype','name','display_column'),
  ('billing_instalmenttype','instalment_plan','display_column'),
  ('billing_instalmenttype','commission_payment_schedule','display_column'),
  ('billing_instalmenttype','commission_deduction_percent','display_column'),
  ('billing_instalmenttype','is_deleted','filter_condition'),
  
  -- policy_fairdeesale_historical
  ('policy_fairdeesale_historical','id','display_column'),
  ('policy_fairdeesale_historical','history_date','date_filter'),
  ('policy_fairdeesale_historical','payment_status','filter_condition'),
  ('policy_fairdeesale_historical','policy_status','filter_condition'),
  
  -- policy_fairdeepolicy
  ('policy_fairdeepolicy','id','display_column'),
  ('policy_fairdeepolicy','policy_number','display_column'),
  ('policy_fairdeepolicy','garage_type','filter_condition'),
  
  -- masterdata_pricelist
  ('masterdata_pricelist','id','display_column'),
  ('masterdata_pricelist','gross_premium','display_column'),
  ('masterdata_pricelist','tax','display_column'),
  ('masterdata_pricelist','duty','display_column'),
  ('masterdata_pricelist','insurer_id','display_column'),
  ('masterdata_pricelist','insurance_class','display_column'),
  ('masterdata_pricelist','for_renewal','filter_condition'),
  ('masterdata_pricelist','is_manual','filter_condition')
)
INSERT INTO node_columns (node_id, column_name, query_role, created_by)
SELECT n.id, c.column_name, c.query_role, 1
FROM c
JOIN nodes n ON n.table_name = c.table_name
ON CONFLICT (node_id, column_name) DO NOTHING;

-- =========================
-- 3) Column Values (Set A filter_condition columns only)
-- =========================
WITH v(table_name, column_name, value_text) AS (
  VALUES
  -- billing_invoicedetail
  ('billing_invoicedetail','detail_type','instalment_penalty'),
  
  -- billing_payment
  ('billing_payment','is_deleted','0'),
  ('billing_payment','is_reconciled','1'),
  
  -- billing_invoice
  ('billing_invoice','is_deleted','0'),
  ('billing_invoice','payer','customer'),
  ('billing_invoice','payee','fairdee'),
  
  -- policy_fairdeesale
  ('policy_fairdeesale','sale_type','instalment'),
  ('policy_fairdeesale','sale_type','credit'),
  ('policy_fairdeesale','sale_type','cbc_to_fairdee'),
  ('policy_fairdeesale','sale_type','cbc_to_insurer'),
  ('policy_fairdeesale','payment_status','credit_approved'),
  ('policy_fairdeesale','payment_status','payment_verified'),
  ('policy_fairdeesale','payment_status','commission_transferred'),
  ('policy_fairdeesale','policy_status','docs_rejected'),
  
  -- policy_fairdeesale_historical
  ('policy_fairdeesale_historical','payment_status','payment_verified'),
  ('policy_fairdeesale_historical','payment_status','credit_approved'),
  ('policy_fairdeesale_historical','payment_status','commission_transferred'),
  ('policy_fairdeesale_historical','policy_status','docs_rejected'),
  
  -- billing_instalmenttype
  ('billing_instalmenttype','is_deleted','0'),
  
  -- utils_fairdeequotation
  ('utils_fairdeequotation','commission_rate','0'),
  ('utils_fairdeequotation','needs_compulsory_insurance','1')
)
INSERT INTO column_values (node_column_id, value, created_by)
SELECT nc.id, v.value_text, 1
FROM v
JOIN nodes n        ON n.table_name = v.table_name
JOIN node_columns nc ON nc.node_id = n.id
                     AND nc.column_name = v.column_name
                     AND nc.query_role  = 'filter_condition'
ON CONFLICT (node_column_id, value) DO NOTHING;

-- =========================
-- 4) Edges (Set A only)
-- =========================
WITH e AS (
  SELECT * FROM (VALUES
    ('policy_fairdeesaleinvoice','invoice_id','billing_invoice','id','N:1',1),
    ('policy_fairdeesaleinvoice','fairdee_sale_id','policy_fairdeesale','id','N:1',1),
    
    ('billing_payment_invoices','invoice_id','billing_invoice','id','N:1',1),
    ('billing_payment_invoices','payment_id','billing_payment','id','N:1',1),
    
    ('billing_invoicedetail','invoice_id','billing_invoice','id','N:1',1),
    
    ('policy_fairdeesale','quotation_id','utils_fairdeequotation','id','N:1',3),
    ('utils_fairdeequotation','quotation_query_id','utils_fairdeequotationquery','id','N:1',3),
    ('utils_fairdeequotationquery','instalment_type_id','billing_instalmenttype','id','N:1',2),
    
    ('utils_fairdeequotation','price_list_id','masterdata_pricelist','id','N:1',2),
    
    ('policy_fairdeesale_historical','id','policy_fairdeesale','id','1:1',2),
    
    ('policy_fairdeesale','voluntary_policy_id','policy_fairdeepolicy','id','N:1',1)
  ) AS x(from_table, from_column, to_table, to_column, cardinality, weight)
)
INSERT INTO nodes_connection
      (from_node_id, from_column, to_node_id, to_column, cardinality, weight, created_by)
SELECT nf.id, e.from_column, nt.id, e.to_column, e.cardinality, e.weight, 1
FROM e
JOIN nodes nf ON nf.table_name = e.from_table
JOIN nodes nt ON nt.table_name = e.to_table
ON CONFLICT DO NOTHING;