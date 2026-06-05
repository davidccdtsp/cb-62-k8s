import { Controller, Get, Param, NotFoundException, Logger } from '@nestjs/common';
import { ApiTags, ApiBearerAuth } from '@nestjs/swagger';
import { DataService } from '../shared/data.service';
import { TelemetryService } from '../shared/telemetry.service';
import { TenantId, ApiTenantQuery } from '../auth/tenant.decorator';

const rand  = (min: number, max: number) => Math.random() * (max - min) + min;
const sleep = (ms: number) => new Promise(r => setTimeout(r, ms));

@ApiTags('products')
@ApiBearerAuth()
@Controller('products')
export class ProductsController {
  private readonly logger = new Logger(ProductsController.name);

  constructor(private readonly data: DataService, private readonly tel: TelemetryService) {}

  @Get()
  @ApiTenantQuery()
  async listProducts(@TenantId() tenantId: string) {
    this.tel.record(tenantId, '/products');
    await sleep(rand(10, 100));
    this.logger.log(`listing products count=${this.data.products.length} tenant_id=${tenantId}`);
    return this.data.products;
  }

  @Get(':id')
  @ApiTenantQuery()
  async getProduct(@Param('id') id: string, @TenantId() tenantId: string) {
    this.tel.record(tenantId, '/products/{id}');
    await sleep(rand(10, 150));
    const product = this.data.products.find(p => p.id === +id);
    if (!product) {
      this.logger.warn(`product not found product_id=${id} tenant_id=${tenantId}`);
      throw new NotFoundException('Product not found');
    }
    this.logger.log(`retrieved product product_id=${id} tenant_id=${tenantId}`);
    return product;
  }
}
