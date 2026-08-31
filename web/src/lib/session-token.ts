let currentToken: string | null = null

export const sessionTokenStore = {
  read: () => currentToken,
  write: (token: string) => {
    currentToken = token
  },
  clear: () => {
    currentToken = null
  },
}
