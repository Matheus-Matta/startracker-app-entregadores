import 'package:flutter/material.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/session_storage.dart';
import '../../delivery/view/delivery_page.dart';
import '../data/auth_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  final _userFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  late final AuthService _authService;
  bool _rememberMe = false;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    const storage = SessionStorage();
    _authService = AuthService(
      apiClient: ApiClient(baseUrl: AppConfig.backendUrl, storage: storage),
      storage: storage,
    );
  }

  @override
  void dispose() {
    _userController.dispose();
    _passwordController.dispose();
    _userFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isLoading || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _authService.login(
        identifier: _userController.text.trim(),
        password: _passwordController.text,
        rememberSession: _rememberMe,
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const DeliveryPage()),
      );
    } on AuthException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showUnavailableMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 18),
                      const _BrandHeader(),
                      const SizedBox(height: 138),
                      const Text(
                        'BEM-VINDO DE VOLTA',
                        style: TextStyle(
                          color: Color(0xFFFF4D0A),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 2.6,
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Acesse sua conta',
                        style: TextStyle(
                          color: Color(0xFF050818),
                          fontSize: 28,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.8,
                        ),
                      ),
                      const SizedBox(height: 18),
                      const Text(
                        'Entre para acompanhar seus ativos, alertas e\nindicadores em tempo real.',
                        style: TextStyle(
                          color: Color(0xFF7183A1),
                          fontSize: 13.5,
                          height: 1.8,
                        ),
                      ),
                      const SizedBox(height: 30),
                      _LoginField(
                        controller: _userController,
                        focusNode: _userFocusNode,
                        label: 'Usuário',
                        hint: 'seu.usuario',
                        autofillHints: const [
                          AutofillHints.username,
                          AutofillHints.email,
                        ],
                        textInputAction: TextInputAction.next,
                        validator: (value) =>
                            value == null || value.trim().isEmpty
                            ? 'Informe seu usuário'
                            : null,
                      ),
                      const SizedBox(height: 20),
                      _LoginField(
                        controller: _passwordController,
                        focusNode: _passwordFocusNode,
                        label: 'Senha',
                        hint: 'Digite sua senha',
                        obscureText: true,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _submit(),
                        validator: (value) => value == null || value.isEmpty
                            ? 'Informe sua senha'
                            : null,
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          SizedBox(
                            width: 18,
                            height: 18,
                            child: Checkbox(
                              value: _rememberMe,
                              onChanged: (value) =>
                                  setState(() => _rememberMe = value ?? false),
                              activeColor: const Color(0xFF050818),
                              side: const BorderSide(color: Color(0xFF929292)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Text(
                            'Manter conectado',
                            style: TextStyle(
                              color: Color(0xFF7183A1),
                              fontSize: 12,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => _showUnavailableMessage(
                              'Recuperação de senha em breve.',
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF111827),
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 36),
                            ),
                            child: const Text(
                              'Esqueceu a senha?',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 15),
                      if (_errorMessage case final message?) ...[
                        Text(
                          message,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFDC2626),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      SizedBox(
                        height: 44,
                        child: FilledButton(
                          onPressed: _isLoading ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF020617),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(11),
                            ),
                            elevation: 5,
                            shadowColor: const Color(0x33020617),
                          ),
                          child: _isLoading
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text(
                                  'Entrar na plataforma',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),
                      const Spacer(),
                      const Padding(
                        padding: EdgeInsets.only(top: 48, bottom: 20),
                        child: Text(
                          '© 2026 Star Tracker. Ambiente protegido.',
                          style: TextStyle(
                            color: Color(0xFF8DA0BD),
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Image.asset('logo.png', width: 48, height: 48, fit: BoxFit.contain),
        const SizedBox(width: 10),
        const Text(
          'Star Tracker',
          style: TextStyle(
            color: Color(0xFF050818),
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _LoginField extends StatelessWidget {
  const _LoginField({
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.hint,
    required this.textInputAction,
    required this.validator,
    this.autofillHints,
    this.obscureText = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final String hint;
  final bool obscureText;
  final Iterable<String>? autofillHints;
  final TextInputAction textInputAction;
  final FormFieldValidator<String> validator;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF34445E),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 9),
        TextFormField(
          controller: controller,
          focusNode: focusNode,
          autofillHints: autofillHints,
          keyboardType: obscureText
              ? TextInputType.visiblePassword
              : TextInputType.text,
          obscureText: obscureText,
          enableSuggestions: !obscureText,
          autocorrect: !obscureText,
          textInputAction: textInputAction,
          onFieldSubmitted: onSubmitted,
          validator: validator,
          style: const TextStyle(color: Color(0xFF111827), fontSize: 13.5),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(
              color: Color(0xFFA5B3C9),
              fontSize: 13.5,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 15,
              vertical: 13,
            ),
            filled: true,
            fillColor: Colors.white,
            enabledBorder: _border(const Color(0xFFDDE4EC)),
            focusedBorder: _border(const Color(0xFF7183A1)),
            errorBorder: _border(const Color(0xFFDC2626)),
            focusedErrorBorder: _border(const Color(0xFFDC2626)),
          ),
        ),
      ],
    );
  }

  OutlineInputBorder _border(Color color) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(11),
    borderSide: BorderSide(color: color),
  );
}
