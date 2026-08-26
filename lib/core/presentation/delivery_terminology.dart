String useDeliveryTerminology(String text) => text
    .replaceAll(RegExp(r'\bWaves\b'), 'Cargas')
    .replaceAll(RegExp(r'\bwaves\b'), 'cargas')
    .replaceAll(RegExp(r'\bWave\b'), 'Carga')
    .replaceAll(RegExp(r'\bwave\b'), 'carga');
