package com.acme.order;

import com.baomidou.mybatisplus.annotation.TableField;
import com.baomidou.mybatisplus.annotation.TableName;

/**
 * 订单主表实体。字段与 order_main 表一一对应。
 */
@TableName("order_main")
public class Order {

    private Long id;

    @TableField("applicant_name")
    private String applicantName;

    public Long getId() { return id; }

    public String getApplicantName() { return applicantName; }

    public void setApplicantName(String applicantName) { this.applicantName = applicantName; }
}