import { Controller, Get, Post, Body, NotFoundException, ConflictException, Logger, HttpCode } from '@nestjs/common';
import { ApiTags, ApiBearerAuth } from '@nestjs/swagger';
import { DataService } from '../shared/data.service';
import { TelemetryService } from '../shared/telemetry.service';
import { TenantId, ApiTenantQuery } from '../auth/tenant.decorator';
import { CreateOrderDto } from './create-order.dto';

const rand  = (min: number, max: number) => Math.random() * (max - min) + min;
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

@ApiTags('orders')
@ApiBearerAuth()
@Controller('orders')
export class OrdersController {
  private readonly logger = new Logger(OrdersController.name);

  constructor(private readonly data: DataService, private readonly tel: TelemetryService) {}

  @Get()
  @ApiTenantQuery()
  async listOrders(@TenantId() tenantId: string) {
    this.tel.record(tenantId, '/orders');
    await sleep(rand(50, 200));
    this.logger.log(`listing orders count=${this.data.orders.length} tenant_id=${tenantId}`);
    return this.data.orders;
  }

  @Post()
  @HttpCode(201)
  @ApiTenantQuery()
  async createOrder(@Body() dto: CreateOrderDto, @TenantId() tenantId: string) {
    this.tel.record(tenantId, 'POST /orders');
    await sleep(rand(100, 300));
    const product = this.data.products.find(p => p.id === dto.product_id);
    if (!product) {
      this.logger.warn(`order creation failed: product not found product_id=${dto.product_id} tenant_id=${tenantId}`);
      throw new NotFoundException('Product not found');
    }
    if (product.stock < dto.quantity) {
      this.logger.warn(`order creation failed: insufficient stock product_id=${dto.product_id} tenant_id=${tenantId}`);
      throw new ConflictException('Insufficient stock');
    }
    const newOrder = { id: this.data.orders.length + 1, product_id: dto.product_id, quantity: dto.quantity, status: 'pending' };
    this.data.orders.push(newOrder);
    this.logger.log(`order created order_id=${newOrder.id} product_id=${dto.product_id} tenant_id=${tenantId}`);
    return newOrder;
  }
}
