package com.acme.order;

import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

import java.util.List;

@Mapper
public interface OrderMapper {

    List<OrderVo> searchByApplicant(@Param("applicantName") String applicantName);
}