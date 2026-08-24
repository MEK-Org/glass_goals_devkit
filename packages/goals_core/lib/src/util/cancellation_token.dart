class CancellationToken {
  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
  }
}
