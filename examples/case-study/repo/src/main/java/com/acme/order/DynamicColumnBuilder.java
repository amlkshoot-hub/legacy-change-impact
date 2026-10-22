package com.acme.order;

/**
 * 历史遗留：列名由前缀拼接而来，静态扫描无法还原。
 */
public class DynamicColumnBuilder {

    private static final String COL_PREFIX = "applicant";

    public String columnName() {
        return COL_PREFIX + "_name";
    }
}