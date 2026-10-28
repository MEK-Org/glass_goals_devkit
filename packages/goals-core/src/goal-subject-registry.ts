import { Goal } from "./model";
import { BehaviorSubject } from "./subject";

/**
 * Port of `GoalSubjectRegistry`: one subject per watched goal, so a change to
 * a goal notifies only the watchers of that goal.
 */
export class GoalSubjectRegistry {
  private readonly subjects = new Map<string, BehaviorSubject<Goal | null>>();

  getOrCreate(
    goalId: string,
    initial: () => Goal | null,
  ): BehaviorSubject<Goal | null> {
    const existing = this.subjects.get(goalId);
    if (existing) {
      return existing;
    }
    const subject = new BehaviorSubject<Goal | null>(initial());
    this.subjects.set(goalId, subject);
    return subject;
  }

  get(goalId: string): BehaviorSubject<Goal | null> | undefined {
    return this.subjects.get(goalId);
  }

  has(goalId: string): boolean {
    return this.subjects.has(goalId);
  }

  emit(goalId: string, goal: Goal | null): void {
    this.subjects.get(goalId)?.add(goal);
  }

  close(goalId: string): void {
    const subject = this.subjects.get(goalId);
    this.subjects.delete(goalId);
    subject?.close();
  }

  closeAll(): void {
    for (const subject of this.subjects.values()) {
      subject.close();
    }
    this.subjects.clear();
  }

  get subjectIds(): string[] {
    return [...this.subjects.keys()];
  }

  get numSubjects(): number {
    return this.subjects.size;
  }
}
