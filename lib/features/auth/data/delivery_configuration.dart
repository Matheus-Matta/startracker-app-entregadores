const deliveryConfigurationKeys = <String>{
  'require_photo',
  'minimum_photos',
  'maximum_photos',
  'require_signature',
  'require_recipient_name',
  'require_document',
  'require_note_on_failure',
  'capture_timestamp',
  'pickup_enabled',
  'pickup_barcode_source',
  'label_scope',
  'pickup_label_scope',
  'label_granularity',
  'pickup_label_granularity',
  'label_print_scope',
  'label_code_format',
  'label_width_mm',
  'label_height_mm',
  'availability',
  'confirmation_location',
  'version',
};

Map<String, dynamic> deliveryConfigurationFromResponse(dynamic data) {
  dynamic raw = data;
  if (data is Map) {
    raw = data['delivery_config'] ?? data['config'] ?? data;
    if (data['account'] is Map) {
      final account = data['account'] as Map;
      raw =
          data['delivery_config'] ??
          account['delivery_config'] ??
          account['config'] ??
          raw;
    }
    if (data['delivery'] is Map) {
      raw =
          data['delivery_config'] ?? (data['delivery'] as Map)['config'] ?? raw;
    }
    if (data['results'] is List && (data['results'] as List).isNotEmpty) {
      raw = (data['results'] as List).first;
    }
  }
  if (raw is! Map) return const {};
  final result = Map<String, dynamic>.from(raw);
  result.removeWhere((key, _) => !deliveryConfigurationKeys.contains(key));
  return result;
}

class AvailabilityOption {
  const AvailabilityOption({required this.value, required this.label});

  final String value;
  final String label;

  factory AvailabilityOption.fromJson(Map<String, dynamic> data) =>
      AvailabilityOption(
        value: data['value']?.toString().trim() ?? '',
        label: data['label']?.toString().trim() ?? '',
      );
}

class DriverAvailability {
  const DriverAvailability({
    required this.canEdit,
    required this.driverId,
    required this.value,
    required this.label,
    required this.options,
    required this.updateUrl,
    required this.method,
  });

  final bool canEdit;
  final int? driverId;
  final String value;
  final String label;
  final List<AvailabilityOption> options;
  final String updateUrl;
  final String method;

  bool get canBeChanged =>
      canEdit &&
      options.isNotEmpty &&
      updateUrl.isNotEmpty &&
      method.isNotEmpty;

  factory DriverAvailability.fromConfiguration(Map<String, dynamic> config) {
    final raw = config['availability'];
    final data = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    final rawOptions = data['options'];
    final options = rawOptions is List
        ? rawOptions
              .whereType<Map>()
              .map(
                (item) => AvailabilityOption.fromJson(
                  Map<String, dynamic>.from(item),
                ),
              )
              .where((item) => item.value.isNotEmpty && item.label.isNotEmpty)
              .toList(growable: false)
        : const <AvailabilityOption>[];
    return DriverAvailability(
      canEdit: _asBool(data['can_edit']),
      driverId: _asInt(data['driver_id']),
      value: data['value']?.toString() ?? '',
      label: data['label']?.toString() ?? '',
      options: options,
      updateUrl: data['update_url']?.toString().trim() ?? '',
      method: data['method']?.toString().trim().toUpperCase() ?? '',
    );
  }

  DriverAvailability withApiResponse(dynamic response) {
    final data = response is Map
        ? Map<String, dynamic>.from(response)
        : const <String, dynamic>{};
    final nextValue =
        (data['availability'] ?? data['value'])?.toString() ?? value;
    final optionLabel = options
        .where((item) => item.value == nextValue)
        .map((item) => item.label)
        .firstOrNull;
    return DriverAvailability(
      canEdit: data['can_edit_availability'] is bool
          ? data['can_edit_availability'] as bool
          : canEdit,
      driverId: _asInt(data['id']) ?? driverId,
      value: nextValue,
      label:
          (data['availability_label'] ?? data['label'])?.toString() ??
          optionLabel ??
          label,
      options: options,
      updateUrl: updateUrl,
      method: method,
    );
  }

  Map<String, dynamic> toJson() => {
    'can_edit': canEdit,
    'driver_id': driverId,
    'value': value,
    'label': label,
    'options': [
      for (final option in options)
        {'value': option.value, 'label': option.label},
    ],
    'update_url': updateUrl,
    'method': method,
  };
}

class ConfirmationLocationPolicy {
  const ConfirmationLocationPolicy({
    required this.enabled,
    required this.required,
    required this.requestFreshLocation,
    required this.completeUrlTemplate,
    required this.method,
    required this.latitudeField,
    required this.longitudeField,
    required this.compareWithPlannedDestination,
    required this.plannedDestinationRadiusM,
    required this.compareWithTrackerWhenAvailable,
    required this.trackerRadiusM,
    required this.trackerTimeToleranceMinutes,
  });

  final bool enabled;
  final bool required;
  final bool requestFreshLocation;
  final String completeUrlTemplate;
  final String method;
  final String latitudeField;
  final String longitudeField;
  final bool compareWithPlannedDestination;
  final double? plannedDestinationRadiusM;
  final bool compareWithTrackerWhenAvailable;
  final double? trackerRadiusM;
  final int? trackerTimeToleranceMinutes;

  static const disabled = ConfirmationLocationPolicy(
    enabled: false,
    required: false,
    requestFreshLocation: false,
    completeUrlTemplate: '',
    method: '',
    latitudeField: '',
    longitudeField: '',
    compareWithPlannedDestination: false,
    plannedDestinationRadiusM: null,
    compareWithTrackerWhenAvailable: false,
    trackerRadiusM: null,
    trackerTimeToleranceMinutes: null,
  );

  bool get canRequestLocation =>
      enabled && latitudeField.isNotEmpty && longitudeField.isNotEmpty;

  factory ConfirmationLocationPolicy.fromConfiguration(
    Map<String, dynamic> config,
  ) {
    final raw = config['confirmation_location'];
    final data = raw is Map
        ? Map<String, dynamic>.from(raw)
        : const <String, dynamic>{};
    return ConfirmationLocationPolicy(
      enabled: _asBool(data['enabled']),
      required: _asBool(data['required']),
      requestFreshLocation: _asBool(data['request_fresh_location']),
      completeUrlTemplate:
          data['complete_url_template']?.toString().trim() ?? '',
      method: data['method']?.toString().trim().toUpperCase() ?? '',
      latitudeField: data['latitude_field']?.toString().trim() ?? '',
      longitudeField: data['longitude_field']?.toString().trim() ?? '',
      compareWithPlannedDestination: _asBool(
        data['compare_with_planned_destination'],
      ),
      plannedDestinationRadiusM: _asDouble(
        data['planned_destination_radius_m'],
      ),
      compareWithTrackerWhenAvailable: _asBool(
        data['compare_with_tracker_when_available'],
      ),
      trackerRadiusM: _asDouble(data['tracker_radius_m']),
      trackerTimeToleranceMinutes: _asInt(
        data['tracker_time_tolerance_minutes'],
      ),
    );
  }

  String completionUrl(int stopId) =>
      completeUrlTemplate.replaceAll('{stop_id}', '$stopId');
}

bool _asBool(dynamic value) => switch (value) {
  bool boolean => boolean,
  String text when text.toLowerCase() == 'true' => true,
  num number => number != 0,
  _ => false,
};

int? _asInt(dynamic value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text),
  _ => null,
};

double? _asDouble(dynamic value) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text),
  _ => null,
};
