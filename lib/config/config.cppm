export module telar.config;

export import telar.lua;

export import telar.base.text;

export import telar.platform;

export import telar.plugins;

// Aggregates the per-process modules while importers move to the ones they use.
export import telar.config.client;
export import telar.config.core;
export import telar.config.gui;
export import telar.config.runtime;
export import telar.config.snapshot;
