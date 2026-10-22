package com.acme.order;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * 对外返回结构。前端按 applicantName 取值，改名即破坏契约。
 */
public class OrderVo {

    private Long id;

    @JsonProperty("applicantName")
    private String applicantName;

    public String getApplicantName() { return applicantName; }
}