import React from 'react';

interface IconProps extends React.SVGProps<SVGSVGElement> {
  size?: number;
  className?: string;
}

/**
 * Cybernetic Keyhole Icon - Combining an OpenSSH cryptographic key with a concentric tunnel conduit
 */
export const CyberKeyholeIcon: React.FC<IconProps> = ({ size = 20, className = '', ...props }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
    className={`shrink-0 ${className}`}
    {...props}
  >
    {/* Outer Hex Tunnel */}
    <path
      d="M12 2L20 6.5V17.5L12 22L4 17.5V6.5L12 2Z"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
    {/* Concentric Conduit Ring */}
    <circle cx="12" cy="10" r="3.5" stroke="currentColor" strokeWidth="1.5" />
    {/* Key Stem & Cryptographic Teeth */}
    <path
      d="M12 13.5V18.5M12 16H14.5M12 18H14"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
    {/* Internal Quantum Node */}
    <circle cx="12" cy="10" r="1.2" fill="currentColor" />
  </svg>
);

/**
 * Tunnel Conduit Icon - Ingress stream channels with packet telemetry
 */
export const TunnelConduitIcon: React.FC<IconProps> = ({ size = 20, className = '', ...props }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
    className={`shrink-0 ${className}`}
    {...props}
  >
    <path
      d="M2 8C2 6.89543 2.89543 6 4 6H20C21.1046 6 22 6.89543 22 8V16C22 17.1046 21.1046 18 20 18H4C2.89543 18 2 17.1046 2 16V8Z"
      stroke="currentColor"
      strokeWidth="1.6"
    />
    <path d="M7 6V18M12 6V18M17 6V18" stroke="currentColor" strokeWidth="1.2" strokeDasharray="2 2" />
    <path d="M9 12H15M14 9.5L16.5 12L14 14.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

/**
 * Port Guard Isolation Icon - Hardware lock for Port 3000
 */
export const PortGuardIcon: React.FC<IconProps> = ({ size = 20, className = '', ...props }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
    className={`shrink-0 ${className}`}
    {...props}
  >
    <rect x="5" y="10" width="14" height="11" rx="2" stroke="currentColor" strokeWidth="1.6" />
    <path
      d="M8 10V7C8 4.79086 9.79086 3 12 3C14.2091 3 16 4.79086 16 7V10"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
    />
    <circle cx="12" cy="15.5" r="1.5" fill="currentColor" />
    <line x1="12" y1="17" x2="12" y2="18.5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
  </svg>
);

/**
 * Bastion Shield Icon - OpenSSH host security with cryptographic nodes
 */
export const BastionShieldIcon: React.FC<IconProps> = ({ size = 20, className = '', ...props }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
    className={`shrink-0 ${className}`}
    {...props}
  >
    <path
      d="M12 2.5L20 5.5V11.5C20 16.5 16.5 20.5 12 22C7.5 20.5 4 16.5 4 11.5V5.5L12 2.5Z"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinejoin="round"
    />
    <path d="M12 7V17M8 11L12 15L16 11" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    <circle cx="12" cy="7" r="1.2" fill="currentColor" />
  </svg>
);

/**
 * Telemetry Radar Icon - Sweeping scan for active tunnel ingress
 */
export const TelemetryRadarIcon: React.FC<IconProps> = ({ size = 20, className = '', ...props }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
    className={`shrink-0 ${className}`}
    {...props}
  >
    <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.6" />
    <circle cx="12" cy="12" r="5" stroke="currentColor" strokeWidth="1.2" strokeDasharray="3 3" />
    <circle cx="12" cy="12" r="1.5" fill="currentColor" />
    <path d="M12 12L19 8.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
  </svg>
);

/**
 * SFTP Exchange Icon - Encrypted secure bidirectional file protocol
 */
export const SftpExchangeIcon: React.FC<IconProps> = ({ size = 20, className = '', ...props }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    xmlns="http://www.w3.org/2000/svg"
    className={`shrink-0 ${className}`}
    {...props}
  >
    <path d="M4 7H16M16 7L12.5 3.5M16 7L12.5 10.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    <path d="M20 17H8M8 17L11.5 13.5M8 17L11.5 20.5" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);
