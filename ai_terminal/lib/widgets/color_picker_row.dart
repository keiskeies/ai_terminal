import 'package:flutter/material.dart';
import '../core/constants.dart';

class ColorPickerRow extends StatelessWidget {
  final String? selectedColor;
  final ValueChanged<String?> onColorSelected;

  const ColorPickerRow({
    super.key,
    this.selectedColor,
    required this.onColorSelected,
  });

  Color get _selectedColor {
    if (selectedColor == null) return Colors.transparent;
    return Color(int.parse(selectedColor!.replaceFirst('#', '0xFF')));
  }

  String? _colorToHex(Color color) {
    return '#${color.value.toRadixString(16).substring(2).toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: tagColors.map((color) {
        final isSelected = selectedColor != null && _selectedColor.value == color.value;
        return GestureDetector(
          onTap: () => onColorSelected(_colorToHex(color)),
          child: Container(
            width: 32,
            height: 32,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: isSelected
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
            ),
            child: isSelected
                ? const Icon(Icons.check, color: Colors.white, size: 16)
                : null,
          ),
        );
      }).toList(),
    );
  }
}
