import { ApiProperty } from '@nestjs/swagger';

export class CreateOrderDto {
  @ApiProperty({ example: 1 })
  product_id: number;

  @ApiProperty({ example: 2 })
  quantity: number;
}
