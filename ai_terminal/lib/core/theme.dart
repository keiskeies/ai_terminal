import 'package:flutter/material.dart';
import 'constants.dart';

class AppTheme {
  static final ThemeData darkTheme = ThemeData.dark().copyWith(
      colorScheme: const ColorScheme.dark(
        primary: cBrand,
        onPrimary: cBg,
        secondary: cGold,
        onSecondary: cBg,
        error: cStatusError,
        onError: cBg,
        surface: cCard,
        onSurface: cTextMain,
        surfaceContainerHighest: cSurface,
        outline: cBorder,
        outlineVariant: cHairline,
      ),
      scaffoldBackgroundColor: cBg,
      appBarTheme: const AppBarTheme(
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
          borderSide: const BorderSide(color: cBrand, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cStatusError),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cStatusError, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: const TextStyle(color: cTextMuted),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(
          color: cTextMain,
          fontSize: fBody,
          fontWeight: FontWeight.w500,
        ),
        bodySmall: TextStyle(
          color: cTextSub,
          fontSize: fSmall,
          fontWeight: FontWeight.w500,
        ),
        titleLarge: TextStyle(color: cTextMain, fontSize: fTitle, fontWeight: FontWeight.w500),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return cBrandPressed;
            if (states.contains(WidgetState.hovered)) return cBrandHover;
            if (states.contains(WidgetState.disabled)) return cBrand.withValues(alpha: 0.4);
            return cBrand;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return cBg.withValues(alpha: 0.6);
            return cBg;
          }),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(rButton)),
          ),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          elevation: WidgetStateProperty.all(0),
          minimumSize: WidgetStateProperty.all(const Size(0, 36)),
          overlayColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return cCardElevated;
            if (states.contains(WidgetState.hovered)) return const Color(0xFF262B2B);
            return cSurface;
          }),
          foregroundColor: WidgetStateProperty.all(cTextBody),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(rButton)),
          ),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered)) return const BorderSide(color: cBorderHover);
            return const BorderSide(color: cBorder);
          }),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          minimumSize: WidgetStateProperty.all(const Size(0, 36)),
          overlayColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: cTextSub,
          side: const BorderSide(color: cBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rButton),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          minimumSize: const Size(0, 36),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: cTextSub,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rButton),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          minimumSize: const Size(0, 32),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return cCardElevated;
            if (states.contains(WidgetState.hovered)) return cSurface;
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return cTextMuted;
            if (states.contains(WidgetState.hovered)) return cTextBody;
            return cTextSub;
          }),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSmall)),
          ),
          minimumSize: WidgetStateProperty.all(const Size(32, 32)),
          overlayColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: cSurface,
        selectedColor: cBrand.withValues(alpha: 0.14),
        disabledColor: cSurface.withValues(alpha: 0.5),
        labelStyle: const TextStyle(color: cTextBody, fontSize: fMicro, fontWeight: FontWeight.w500),
        secondaryLabelStyle: const TextStyle(color: cBrand, fontSize: fMicro, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rFull),
          side: const BorderSide(color: cBorder),
        ),
        side: const BorderSide(color: cBorder),
        elevation: 0,
      ),
      tabBarTheme: const TabBarThemeData(
        dividerColor: cHairline,
        indicatorColor: cBrand,
        labelColor: cTextMain,
        unselectedLabelColor: cTextSub,
        labelStyle: TextStyle(fontSize: fSmall, fontWeight: FontWeight.w500),
        unselectedLabelStyle: TextStyle(fontSize: fSmall),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: cBrand,
        foregroundColor: cBg,
        elevation: 0,
        shape: CircleBorder(),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: cCardElevated,
          borderRadius: BorderRadius.circular(rSmall),
          border: Border.all(color: cBorder),
        ),
        textStyle: const TextStyle(color: cTextMain, fontSize: fSmall),
      ),
      dividerTheme: const DividerThemeData(
        color: cHairline,
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

  static final ThemeData lightTheme = ThemeData.light().copyWith(
      colorScheme: const ColorScheme.light(
        primary: cBrandLight,
        onPrimary: Colors.white,
        secondary: cGoldLight,
        onSecondary: Colors.white,
        error: cStatusErrorLight,
        onError: Colors.white,
        surface: cCardLight,
        onSurface: cTextMainLight,
        surfaceContainerHighest: cSurfaceLight,
        outline: cBorderLightTheme,
        outlineVariant: cHairlineLight,
      ),
      scaffoldBackgroundColor: cBgLight,
      appBarTheme: const AppBarTheme(
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
          borderSide: const BorderSide(color: cBrandLight, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cStatusErrorLight),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(rInput),
          borderSide: const BorderSide(color: cStatusErrorLight, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: const TextStyle(color: cTextMutedLight),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(
          color: cTextMainLight,
          fontSize: fBody,
          fontWeight: FontWeight.w500,
        ),
        bodySmall: TextStyle(
          color: cTextSubLight,
          fontSize: fSmall,
          fontWeight: FontWeight.w500,
        ),
        titleLarge: TextStyle(color: cTextMainLight, fontSize: fTitle, fontWeight: FontWeight.w500),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return cBrandLightPressed;
            if (states.contains(WidgetState.hovered)) return cBrandLightHover;
            if (states.contains(WidgetState.disabled)) return cBrandLight.withValues(alpha: 0.4);
            return cBrandLight;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return Colors.white.withValues(alpha: 0.6);
            return Colors.white;
          }),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(rButton)),
          ),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          elevation: WidgetStateProperty.all(0),
          minimumSize: WidgetStateProperty.all(const Size(0, 36)),
          overlayColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return const Color(0xFFDCE3DE);
            if (states.contains(WidgetState.hovered)) return const Color(0xFFEFF2EF);
            return cSurfaceLight;
          }),
          foregroundColor: WidgetStateProperty.all(cTextMainLight),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(rButton)),
          ),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered)) return const BorderSide(color: cBorderLightHover);
            return const BorderSide(color: cBorderLightTheme);
          }),
          padding: WidgetStateProperty.all(
            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          ),
          minimumSize: WidgetStateProperty.all(const Size(0, 36)),
          overlayColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: cTextSubLight,
          side: const BorderSide(color: cBorderLightTheme),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rButton),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          minimumSize: const Size(0, 36),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: cTextSubLight,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(rButton),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          minimumSize: const Size(0, 32),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return cCardElevatedLight;
            if (states.contains(WidgetState.hovered)) return cSurfaceLight;
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return cTextMutedLight;
            if (states.contains(WidgetState.hovered)) return cTextMainLight;
            return cTextSubLight;
          }),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(rSmall)),
          ),
          minimumSize: WidgetStateProperty.all(const Size(32, 32)),
          overlayColor: WidgetStateProperty.all(Colors.transparent),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: cSurfaceLight,
        selectedColor: cBrandLight.withValues(alpha: 0.12),
        disabledColor: cSurfaceLight.withValues(alpha: 0.5),
        labelStyle: const TextStyle(color: cTextMainLight, fontSize: fMicro, fontWeight: FontWeight.w500),
        secondaryLabelStyle: const TextStyle(color: cBrandLight, fontSize: fMicro, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(rFull),
          side: const BorderSide(color: cBorderLightTheme),
        ),
        side: const BorderSide(color: cBorderLightTheme),
        elevation: 0,
      ),
      tabBarTheme: const TabBarThemeData(
        dividerColor: cHairlineLight,
        indicatorColor: cBrandLight,
        labelColor: cTextMainLight,
        unselectedLabelColor: cTextSubLight,
        labelStyle: TextStyle(fontSize: fSmall, fontWeight: FontWeight.w500),
        unselectedLabelStyle: TextStyle(fontSize: fSmall),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: cBrandLight,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: CircleBorder(),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: cCardElevatedLight,
          borderRadius: BorderRadius.circular(rSmall),
          border: Border.all(color: cBorderLightTheme),
        ),
        textStyle: const TextStyle(color: cTextMainLight, fontSize: fSmall),
      ),
      dividerTheme: const DividerThemeData(
        color: cHairlineLight,
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
