import { Injectable } from '@nestjs/common';

export interface Product { id: number; name: string; price: number; stock: number; }
export interface Order  { id: number; product_id: number; quantity: number; status: string; }
export interface User   { id: number; name: string; email: string; }

@Injectable()
export class DataService {
  readonly products: Product[] = [
    { id: 1, name: 'Widget A', price: 9.99,  stock: 100 },
    { id: 2, name: 'Widget B', price: 19.99, stock: 50  },
    { id: 3, name: 'Gadget X', price: 49.99, stock: 25  },
    { id: 4, name: 'Gadget Y', price: 99.99, stock: 10  },
  ];

  readonly orders: Order[] = [
    { id: 1, product_id: 1, quantity: 2, status: 'completed' },
    { id: 2, product_id: 3, quantity: 1, status: 'pending'   },
  ];

  readonly users: User[] = [
    { id: 1, name: 'Alice', email: 'alice@example.com' },
    { id: 2, name: 'Bob',   email: 'bob@example.com'   },
  ];
}
