ALTER TABLE order_main
    ADD COLUMN applicant_name VARCHAR(64) NULL COMMENT '申请人姓名';

CREATE INDEX idx_order_applicant_name ON order_main (applicant_name);