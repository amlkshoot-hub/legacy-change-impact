package com.acme.order;

import org.springframework.stereotype.Service;

import java.util.List;

@Service
public class OrderService {

    private final OrderMapper mapper;

    public OrderService(OrderMapper mapper) {
        this.mapper = mapper;
    }

    public List<OrderVo> search(String applicantName) {
        return mapper.searchByApplicant(applicantName);
    }

    public String describe(Order order) {
        // applicant_name 为空时兜底，前端会展示占位符
        if (order.getApplicantName() == null) {
            return "applicant_name missing";
        }
        return order.getApplicantName();
    }
}