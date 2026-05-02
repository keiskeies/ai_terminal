import 'package:flutter/material.dart';
import 'constants.dart';

class AppTheme {
  static ThemeData get darkTheme {
    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: cBg,
      appBarTheme: AppBarTheme(
        backgroundColor: cCard,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: cTextMain,
          fontSize: fTitle,
          fontWeight: FontWeight.w500,
        ),
        iconTheme: IconThemeData(color: cTextSub),
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: cCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rCard),
        ),
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        fillColor: cSurface,
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cPrimary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cDanger),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: const TextStyle(color: cTextMuted),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: cTextMain, fontSize: fBody),
        bodySmall: TextStyle(color: cTextSub, fontSize: fSmall),
        titleLarge: TextStyle(color: cTextMain, fontSize: fTitle, fontWeight: FontWeight.w500),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: cPrimary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rButton),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: cTextSub,
          side: const BorderSide(color: cBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rButton),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: cBorder,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cCardElevated,
        contentTextStyle: const TextStyle(color: cTextMain),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rButton),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: cCardElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rMedium),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cCardElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rLarge),
        ),
        surfaceTintColor: Colors.transparent,
      ),
      listTileTheme: const ListTileThemeData(
        textColor: cTextMain,
        iconColor: cTextSub,
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        iconColor: cTextSub,
        collapsedIconColor: cTextSub,
        textColor: cTextMain,
        collapsedTextColor: cTextMain,
      ),
    );
  }

  static ThemeData get lightTheme {
    return ThemeData.light().copyWith(
      scaffoldBackgroundColor: cBgLight,
      appBarTheme: AppBarTheme(
        backgroundColor: cCardLight,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: cTextMainLight,
          fontSize: fTitle,
          fontWeight: FontWeight.w500,
        ),
        iconTheme: IconThemeData(color: cTextSubLight),
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: cCardLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rCard),
        ),
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        fillColor: cSurfaceLight,
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cBorderLightTheme),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cBorderLightTheme),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cPrimary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cDanger),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: const TextStyle(color: cTextMutedLight),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: cTextMainLight, fontSize: fBody),
        bodySmall: TextStyle(color: cTextSubLight, fontSize: fSmall),
        titleLarge: TextStyle(color: cTextMainLight, fontSize: fTitle, fontWeight: FontWeight.w500),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: cPrimary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rButton),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: cTextSubLight,
          side: const BorderSide(color: cBorderLightTheme),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rButton),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: cBorderLightTheme,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cCardElevatedLight,
        contentTextStyle: const TextStyle(color: cTextMainLight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rButton),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: cCardElevatedLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rMedium),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cCardElevatedLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rLarge),
        ),
        surfaceTintColor: Colors.transparent,
      ),
      listTileTheme: const ListTileThemeData(
        textColor: cTextMainLight,
        iconColor: cTextSubLight,
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        iconColor: cTextSubLight,
        collapsedIconColor: cTextSubLight,
        textColor: cTextMainLight,
        collapsedTextColor: cTextMainLight,
      ),
    );
  }
}
