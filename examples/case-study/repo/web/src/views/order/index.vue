<template>
  <a-table :columns="columns" :data-source="rows" :pagination="false" />
</template>

<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { searchOrder, type OrderVo } from '@/api/order'

const rows = ref<OrderVo[]>([])

const columns = [
  { title: '申请人', dataIndex: 'applicantName', key: 'applicantName' },
  { title: '订单号', dataIndex: 'id', key: 'id' },
]

onMounted(async () => {
  rows.value = await searchOrder('')
})
</script>