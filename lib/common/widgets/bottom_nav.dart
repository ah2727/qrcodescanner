import 'package:flutter/material.dart';

class BottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const BottomNav({super.key, required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: currentIndex,
      onTap: onTap,
      type: BottomNavigationBarType.fixed,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.usb), label: 'Activate'),
        BottomNavigationBarItem(icon: Icon(Icons.account_balance_wallet_outlined), label: 'Boards'),
        BottomNavigationBarItem(icon: Icon(Icons.key), label: 'Keys'),
        BottomNavigationBarItem(icon: Icon(Icons.supervised_user_circle), label: 'Profiles'),
      ],
    );
  }
}
