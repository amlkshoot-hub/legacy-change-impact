import request from '@/utils/request'

export interface OrderVo {
  id: number
  applicantName: string
}

export function searchOrder(applicantName: string) {
  return request.get('/api/v1/orders', { params: { applicantName } })
}