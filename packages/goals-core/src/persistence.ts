import { AnyOp } from "@thkp-eng/goals-types";

export interface LoadOpsResp {
  ops: AnyOp[];
  /**
   * An opaque string that can be used to represent what has been fetched so
   * far. This will be null if there have been no ops for this user.
   */
  cursor: string | null;
}

export interface PersistenceService {
  save(ops: Iterable<AnyOp>): Promise<void>;
  load(options: {
    cursor?: string | null;
    limit?: number;
  }): Promise<LoadOpsResp>;
  loadString(entryId: string): Promise<string | null>;
  // returns the total number of ops that the user has access to until cursor
  count(options: { cursor?: string | null }): Promise<number>;
  // returns a subscription to new ops
  subscribeJSON(
    cursor: string | null,
    callback: (ops: AnyOp[], cursor: string) => void,
  ): () => void;
}
