import nextPlugin from "eslint-config-next";

const eslintConfig = [
  ...nextPlugin,
  {
    ignores: ["out/**", ".next/**", "src-tauri/**"],
  },
];

export default eslintConfig;
