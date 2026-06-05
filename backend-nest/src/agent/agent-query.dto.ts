import { ApiProperty } from '@nestjs/swagger';

export class AgentQueryDto {
  @ApiProperty({ example: 'gadgets under 50' })
  query: string;
}
