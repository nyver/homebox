import 'package:flutter/material.dart';

void main() => runApp(const HomeBoxApp());

class HomeBoxApp extends StatelessWidget {
  const HomeBoxApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HomeBox',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b87)),
      useMaterial3: true,
    ),
    home: const ServerSetupPage(),
  );
}

class ServerSetupPage extends StatefulWidget {
  const ServerSetupPage({super.key});

  @override
  State<ServerSetupPage> createState() => _ServerSetupPageState();
}

class _ServerSetupPageState extends State<ServerSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _serverController = TextEditingController(
    text: 'http://192.168.1.10:8787',
  );
  final _fingerprintController = TextEditingController();

  @override
  void dispose() {
    _serverController.dispose();
    _fingerprintController.dispose();
    super.dispose();
  }

  void _continueSetup() {
    if (!_formKey.currentState!.validate()) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Secure transport is not configured yet. No credentials or files were sent.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Set up HomeBox')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Icon(Icons.lock_outline, size: 52, color: colors.primary),
                const SizedBox(height: 16),
                Text(
                  'Your files stay encrypted',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'HomeBox encrypts files on this device before upload. Verify the server fingerprint before entering account credentials.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                Form(
                  key: _formKey,
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _serverController,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Server address',
                          hintText: 'https://homebox.example:8787',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          final uri = Uri.tryParse(value?.trim() ?? '');
                          if (uri == null ||
                              !uri.hasScheme ||
                              uri.host.isEmpty) {
                            return 'Enter a complete server address.';
                          }
                          if (uri.scheme != 'https' && uri.scheme != 'http') {
                            return 'Only HTTP or HTTPS server addresses are supported.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _fingerprintController,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Server fingerprint',
                          hintText:
                              'SHA-256 fingerprint from homebox fingerprint',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) =>
                            RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(
                              (value ?? '').replaceAll(RegExp(r'\s'), ''),
                            )
                            ? null
                            : 'Enter the 64-character SHA-256 fingerprint.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Card(
                  color: colors.surfaceContainerHighest,
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Get the fingerprint from a trusted local terminal or administrator. A changed fingerprint must block the connection.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _continueSetup,
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text('Verify and continue'),
                ),
                const SizedBox(height: 12),
                const Text(
                  'E2EE vault: locked until this device is provisioned by a trusted device or Recovery Secret.',
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
