package com.acme.order;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class OrderServiceTest {

    @Test
    void returnsPlaceholderWhenApplicantNameIsNull() {
        Order order = new Order();
        OrderService service = new OrderService(null);
        assertEquals("applicant_name missing", service.describe(order));
    }
}