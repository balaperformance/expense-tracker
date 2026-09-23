import '../models/payment_method.dart';
import '../repositories/payment_method_repository.dart';
import 'async_state.dart';

class PaymentMethodProvider extends AsyncProvider {
  PaymentMethodProvider(this._repository);

  final PaymentMethodRepository _repository;

  List<PaymentMethod> _methods = <PaymentMethod>[];
  String? _userId;

  List<PaymentMethod> get methods => List<PaymentMethod>.unmodifiable(_methods);

  @override
  bool get isEmptyData => _methods.isEmpty;

  PaymentMethod? byId(String? id) {
    if (id == null) return null;
    for (final PaymentMethod m in _methods) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<void> initialise(String userId) async {
    _userId = userId;
    setLoading();
    try {
      _methods = await _repository.ensureDefaults(userId);
      setReady();
    } catch (error) {
      setError(error);
    }
  }

  Future<bool> create(String name) async {
    final String? userId = _userId;
    if (userId == null) return false;

    return guard(() async {
      final PaymentMethod created =
          await _repository.create(userId: userId, name: name);
      _methods = <PaymentMethod>[..._methods, created]
        ..sort((PaymentMethod a, PaymentMethod b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      safeNotify();
    });
  }

  Future<bool> delete(String id) async {
    final String? userId = _userId;
    if (userId == null) return false;

    return guard(() async {
      await _repository.delete(userId: userId, id: id);
      _methods = _methods.where((PaymentMethod m) => m.id != id).toList();
      safeNotify();
    });
  }

  void reset() {
    _methods = <PaymentMethod>[];
    _userId = null;
    safeNotify();
  }
}
