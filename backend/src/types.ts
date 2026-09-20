export interface D1Database {
  prepare(query: string): D1PreparedStatement;
}

export interface D1PreparedStatement {
  bind(...values: unknown[]): D1PreparedStatement;
  run(): Promise<{ success: boolean }>;
  all<T = unknown>(): Promise<{ results?: T[] }>;
}

export interface DeviceRow {
  device_token: string;
  locale: string;
  app_version: string;
  os_version: string;
  is_active: number;
  created_at: number;
  updated_at: number;
}
