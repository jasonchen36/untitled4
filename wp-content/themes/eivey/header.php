<?php
/**
 * The header for our theme.
 *
 * This is the template that displays all of the <head> section and everything up until <div id="content">
 *
 * @link https://developer.wordpress.org/themes/basics/template-files/#template-partials
 *
 * @package eivey
 */

?>
<!DOCTYPE html>
<html <?php language_attributes(); ?>>
<head>
    <meta charset="<?php bloginfo( 'charset' ); ?>">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="profile" href="http://gmpg.org/xfn/11">
    <?php wp_head(); ?>
</head>
<body <?php body_class(); ?>>
<!--desktop menu-->
<header class="grid-container show-for-large">
    <nav id="menu-header-secondary-container" class="small-12 text-right">
        <?php wp_nav_menu(array(
            'theme_location' => 'header_secondary',
            'menu_id' => 'menu-header-secondary',
            'menu_class' => 'standard-menu'
        )); ?>
    </nav>
    <div class="small-12 text-center show-for-large">
        <a href="/">
            <div class="i--icon-logo"></div>
        </a>
        <span id="logo-tagline-border"></span>
        <div id="logo-tagline">
            Buy &amp; Sell Pre-Loved Designer Fashion
        </div>
    </div>
</header>
<!--mobile menu-->
<header id="header-menu-mobile-container" class="small-grid-container hide-for-large">
    <div class="small-3">
        <a href="#">
            <div class="i--icon-menu"></div>
        </a>
    </div>
    <div class="small-6">
        <a href="/">
            <div class="i--icon-logo"></div>
        </a>
    </div>
    <div class="small-3 grid-end">
        <a href="#">
            <div class="i--icon-user"></div>
        </a>
        <a href="#">
            <div class="i--icon-bag"></div>
        </a>
    </div>
    <div class="small-12 no-padding">
        <input type="text" />
    </div>
</header>
<div id="mobile-menu" class="faded-out">
    <?php wp_nav_menu(array(
        'theme_location' => 'homepage',
        'menu_id' => 'menu-categories',
        'menu_class' => 'standard-menu'
    )); ?>
    <?php wp_nav_menu(array(
        'theme_location' => 'header_secondary',
        'menu_id' => 'menu-header-secondary',
        'menu_class' => 'standard-menu'
    )); ?>
</div>