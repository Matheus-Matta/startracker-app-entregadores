class PagedResult<T> {
  const PagedResult({
    required this.items,
    required this.count,
    required this.page,
    required this.hasNext,
    required this.hasPrevious,
  });

  final List<T> items;
  final int count;
  final int page;
  final bool hasNext;
  final bool hasPrevious;
}
